// SimplKernel — OpenCASCADE implementation of the C API in include/SimplKernel.h.
// SPDX-License-Identifier: GPL-3.0-or-later

#include "SimplKernel.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <tuple>
#include <unordered_map>
#include <variant>
#include <vector>

#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepAlgoAPI_Splitter.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_Copy.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepGProp.hxx>
#include <BRepLib_ToolTriangulatedShape.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepTools.hxx>
#include <BRepTools_History.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <GCPnts_TangentialDeflection.hxx>
#include <GProp_GProps.hxx>
#include <GeomAbs_SurfaceType.hxx>
#include <Message.hxx>
#include <Message_Messenger.hxx>
#include <Message_PrinterOStream.hxx>
#include <Poly_Triangulation.hxx>
#include <STEPControl_Writer.hxx>
#include <ShapeUpgrade_UnifySameDomain.hxx>
#include <Standard_Failure.hxx>
#include <StlAPI_Writer.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <NCollection_IndexedDataMap.hxx>
#include <NCollection_IndexedMap.hxx>
#include <NCollection_List.hxx>
#include <TopTools_ShapeMapHasher.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <gp_Ax2.hxx>
#include <gp_Ax3.hxx>
#include <gp_Circ.hxx>
#include <gp_Pln.hxx>
#include <gp_Trsf.hxx>

namespace {

// OCCT 8 retired the TopTools_* collection typedef headers; spell them out once here.
using ShapeList = NCollection_List<TopoDS_Shape>;
using ShapeIndexedMap = NCollection_IndexedMap<TopoDS_Shape, TopTools_ShapeMapHasher>;
using ShapeToShapes = NCollection_IndexedDataMap<TopoDS_Shape, ShapeList, TopTools_ShapeMapHasher>;

// ------------------------------------------------------------------ objects --

/// A sub-shape together with its persistent name.
struct Named {
  TopoDS_Shape shape;
  std::string name;
};

struct Body {
  TopoDS_Shape shape;
  ShapeIndexedMap faces, edges;  // 1-based, fixed order = mesh indices
  std::vector<std::string> faceNames, edgeNames;
  std::vector<bool> edgeHidden;  // seams and degenerated edges: not drawn, not pickable
  std::unordered_map<std::string, int> faceIndex, edgeIndex;  // name -> 0-based index
};

struct Profile {
  TopoDS_Face face;
  std::vector<Named> edgeTags;  // region edge -> sketch curve tag
};

struct Sketch {
  struct Region {
    TopoDS_Face face;
    std::string tags;
    double area = 0, u = 0, v = 0;
  };
  gp_Ax3 frame;
  std::vector<Named> curves;  // original curves
  std::vector<Named> pieces;  // curves split at intersections -> tag
  std::vector<Region> regions;
};

using Object = std::variant<Body, Profile, Sketch>;

std::mutex g_mutex;
std::unordered_map<SKHandle, std::shared_ptr<Object>> g_objects;
SKHandle g_next = 1;
thread_local std::string g_error;

void setError(const std::string &msg) { g_error = msg; }

SKHandle store(Object &&obj) {
  std::lock_guard<std::mutex> lock(g_mutex);
  SKHandle h = g_next++;
  g_objects[h] = std::make_shared<Object>(std::move(obj));
  return h;
}

template <class T>
std::shared_ptr<Object> lookup(SKHandle h, T *&out) {
  std::shared_ptr<Object> obj;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_objects.find(h);
    if (it != g_objects.end()) obj = it->second;
  }
  out = obj ? std::get_if<T>(obj.get()) : nullptr;
  if (!out) setError("invalid handle " + std::to_string(h));
  return obj;
}

#define SK_TRY try {
#define SK_CATCH(ret)                                          \
  }                                                            \
  catch (const Standard_Failure &e) {                          \
    setError(std::string("kernel: ") + e.what());  \
    return ret;                                                \
  }                                                            \
  catch (const std::exception &e) {                            \
    setError(e.what());                                        \
    return ret;                                                \
  }                                                            \
  catch (...) {                                                \
    setError("unknown kernel error");                          \
    return ret;                                                \
  }

// ------------------------------------------------------------------ helpers --

gp_Ax3 toAx3(const SKFrame &f) {
  return gp_Ax3(gp_Pnt(f.ox, f.oy, f.oz), gp_Dir(f.nx, f.ny, f.nz), gp_Dir(f.xx, f.xy, f.xz));
}

gp_Pnt frameToWorld(const gp_Ax3 &a, double u, double v) {
  const gp_Pnt &o = a.Location();
  const gp_Dir &x = a.XDirection(), &y = a.YDirection();
  return gp_Pnt(o.X() + u * x.X() + v * y.X(), o.Y() + u * x.Y() + v * y.Y(),
                o.Z() + u * x.Z() + v * y.Z());
}

/// Deterministic sort key for disambiguating shapes that share a name.
std::tuple<long long, long long, long long> positionKey(const TopoDS_Shape &s) {
  GProp_GProps props;
  if (s.ShapeType() == TopAbs_FACE)
    BRepGProp::SurfaceProperties(s, props);
  else
    BRepGProp::LinearProperties(s, props);
  gp_Pnt c = props.CentreOfMass();
  auto q = [](double x) { return std::llround(x * 1e4); };  // 0.1 µm grid
  return {q(c.X()), q(c.Y()), q(c.Z())};
}

/// Names that occur on more than one shape get "#2", "#3"... in positional order.
void uniquify(const ShapeIndexedMap &shapes, std::vector<std::string> &names) {
  std::unordered_map<std::string, std::vector<int>> groups;
  for (int i = 0; i < (int)names.size(); ++i) groups[names[i]].push_back(i);
  for (auto &[name, idx] : groups) {
    if (idx.size() < 2) continue;
    std::vector<std::pair<std::tuple<long long, long long, long long>, int>> keyed;
    for (int i : idx) keyed.push_back({positionKey(shapes(i + 1)), i});
    std::sort(keyed.begin(), keyed.end());
    for (size_t k = 1; k < keyed.size(); ++k) names[keyed[k].second] = name + "#" + std::to_string(k + 1);
  }
}

/// Builds a Body from a shape and named faces. Unnamed faces get "<fallback>.face".
Body makeBody(const TopoDS_Shape &shape, const std::vector<Named> &named, const std::string &fallback) {
  Body b;
  b.shape = shape;
  TopExp::MapShapes(shape, TopAbs_FACE, b.faces);
  TopExp::MapShapes(shape, TopAbs_EDGE, b.edges);

  b.faceNames.assign(b.faces.Extent(), "");
  for (const Named &n : named) {  // first name wins (callers list the "primary" operand first)
    int idx = b.faces.FindIndex(n.shape);
    if (idx > 0 && b.faceNames[idx - 1].empty()) b.faceNames[idx - 1] = n.name;
  }
  for (auto &n : b.faceNames)
    if (n.empty()) n = fallback + ".face";
  uniquify(b.faces, b.faceNames);

  ShapeToShapes edgeFaces;
  TopExp::MapShapesAndUniqueAncestors(shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
  b.edgeNames.assign(b.edges.Extent(), "");
  b.edgeHidden.assign(b.edges.Extent(), false);
  for (int i = 1; i <= b.edges.Extent(); ++i) {
    const TopoDS_Edge &e = TopoDS::Edge(b.edges(i));
    std::vector<std::string> adj;
    if (edgeFaces.Contains(e))
      for (const TopoDS_Shape &f : edgeFaces.FindFromKey(e)) adj.push_back(b.faceNames[b.faces.FindIndex(f) - 1]);
    std::sort(adj.begin(), adj.end());
    if (adj.size() == 1) adj.push_back(adj[0]);  // seam: same face on both sides
    std::string name;
    for (size_t k = 0; k < adj.size(); ++k) name += (k ? "|" : "") + adj[k];
    b.edgeNames[i - 1] = name.empty() ? fallback + ".edge" : name;
    b.edgeHidden[i - 1] = BRep_Tool::Degenerated(e) || adj.size() < 2 || adj[0] == adj[1];
  }
  uniquify(b.edges, b.edgeNames);

  for (int i = 0; i < (int)b.faceNames.size(); ++i) b.faceIndex[b.faceNames[i]] = i;
  for (int i = 0; i < (int)b.edgeNames.size(); ++i) b.edgeIndex[b.edgeNames[i]] = i;
  return b;
}

std::vector<Named> namedFaces(const Body &b) {
  std::vector<Named> out;
  for (int i = 1; i <= b.faces.Extent(); ++i) out.push_back({b.faces(i), b.faceNames[i - 1]});
  return out;
}

/// Carries names through any OCCT modeling operation using its history.
void carry(BRepBuilderAPI_MakeShape &op, const std::vector<Named> &in, std::vector<Named> &out) {
  for (const Named &n : in) {
    if (op.IsDeleted(n.shape)) continue;
    const ShapeList &mods = op.Modified(n.shape);
    if (mods.IsEmpty()) {
      out.push_back(n);
    } else {
      for (const TopoDS_Shape &m : mods) out.push_back({m, n.name});
    }
  }
}

/// Same, for a BRepTools_History (used by UnifySameDomain).
std::vector<Named> carry(const Handle(BRepTools_History) & h, const std::vector<Named> &in) {
  std::vector<Named> out;
  for (const Named &n : in) {
    if (h->IsRemoved(n.shape)) continue;
    const ShapeList &mods = h->Modified(n.shape);
    if (mods.IsEmpty()) {
      out.push_back(n);
    } else {
      for (const TopoDS_Shape &m : mods) out.push_back({m, n.name});
    }
  }
  return out;
}

/// Merges coplanar / co-cylindrical faces left over from booleans (so e.g. the seam between
/// two joined, flush extrusions disappears and the outer edge can be filleted).
TopoDS_Shape unify(const TopoDS_Shape &s, std::vector<Named> &names) {
  ShapeUpgrade_UnifySameDomain usd(s, true, true, false);
  usd.Build();
  names = carry(usd.History(), names);
  return usd.Shape();
}

std::string featureOrDefault(const char *id, const char *def) { return (id && *id) ? id : def; }

template <class T>
T *copyOut(const std::vector<T> &v) {
  if (v.empty()) return nullptr;
  T *p = static_cast<T *>(std::malloc(v.size() * sizeof(T)));
  std::memcpy(p, v.data(), v.size() * sizeof(T));
  return p;
}

template <class Maker, class AddFn>
SKHandle edgeFeature(SKHandle body, const char *const *edgeNames, int count, const std::string &feat,
                            const char *kind, AddFn add) {
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return 0;
  if (count < 1) {
    setError(std::string(kind) + " needs at least one edge");
    return 0;
  }
  Maker mk(b->shape);
  std::vector<std::pair<TopoDS_Shape, std::string>> used;
  for (int k = 0; k < count; ++k) {
    auto it = b->edgeIndex.find(edgeNames[k]);
    if (it == b->edgeIndex.end()) {
      setError(std::string("edge not found: ") + edgeNames[k]);
      return 0;
    }
    const TopoDS_Edge &e = TopoDS::Edge(b->edges(it->second + 1));
    add(mk, e);
    used.push_back({e, edgeNames[k]});
  }
  mk.Build();
  if (!mk.IsDone()) {
    setError(std::string(kind) + " failed (size too large for the adjacent faces?)");
    return 0;
  }
  std::vector<Named> names;
  carry(mk, namedFaces(*b), names);
  // OCCT extends each picked edge along its tangent chain; name faces after every chain edge,
  // picked edges first so they win if a face is generated from several edges.
  std::vector<std::pair<TopoDS_Shape, std::string>> chain = used;
  for (int ic = 1; ic <= mk.NbContours(); ++ic)
    for (int j = 1; j <= mk.NbEdges(ic); ++j) {
      const TopoDS_Edge &e = mk.Edge(ic, j);
      int idx = b->edges.FindIndex(e);
      if (idx > 0) chain.push_back({e, b->edgeNames[idx - 1]});
    }
  for (auto &[e, en] : chain)
    for (const TopoDS_Shape &g : mk.Generated(e))
      if (g.ShapeType() == TopAbs_FACE) names.push_back({g, feat + "." + kind + "." + en});
  Body out = makeBody(mk.Shape(), names, feat + "." + kind);
  BRepCheck_Analyzer check(out.shape);
  if (!check.IsValid()) {
    setError(std::string(kind) + " produced an invalid solid");
    return 0;
  }
  return store(std::move(out));
}

/// Appends the triangulation of a meshed face (positions, normals, indices, face ids).
void appendFace(const TopoDS_Face &f, uint32_t faceIndex, std::vector<float> &pos, std::vector<float> &nrm,
                std::vector<uint32_t> &idx, std::vector<uint32_t> &triFace) {
  TopLoc_Location loc;
  Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(f, loc);
  if (tri.IsNull()) return;
  if (!tri->HasNormals()) BRepLib_ToolTriangulatedShape::ComputeNormals(f, tri);
  const gp_Trsf tr = loc.Transformation();
  const bool reversed = f.Orientation() == TopAbs_REVERSED;
  const uint32_t base = (uint32_t)(pos.size() / 3);
  for (int n = 1; n <= tri->NbNodes(); ++n) {
    gp_Pnt p = tri->Node(n).Transformed(tr);
    gp_Dir d = tri->Normal(n).Transformed(tr);
    if (reversed) d.Reverse();
    pos.insert(pos.end(), {(float)p.X(), (float)p.Y(), (float)p.Z()});
    nrm.insert(nrm.end(), {(float)d.X(), (float)d.Y(), (float)d.Z()});
  }
  for (int t = 1; t <= tri->NbTriangles(); ++t) {
    int a, c, d;
    tri->Triangle(t).Get(a, c, d);
    if (reversed) std::swap(c, d);
    idx.insert(idx.end(), {base + a - 1, base + c - 1, base + d - 1});
    triFace.push_back(faceIndex);
  }
}

SKMesh *packMesh(const std::vector<float> &pos, const std::vector<float> &nrm, const std::vector<uint32_t> &idx,
                 const std::vector<uint32_t> &triFace, const std::vector<float> &seg,
                 const std::vector<uint32_t> &segEdge) {
  auto *m = static_cast<SKMesh *>(std::calloc(1, sizeof(SKMesh)));
  m->vertexCount = (uint32_t)(pos.size() / 3);
  m->positions = copyOut(pos);
  m->normals = copyOut(nrm);
  m->triangleCount = (uint32_t)triFace.size();
  m->indices = copyOut(idx);
  m->triangleFace = copyOut(triFace);
  m->segmentCount = (uint32_t)segEdge.size();
  m->segments = copyOut(seg);
  m->segmentEdge = copyOut(segEdge);
  return m;
}

}  // namespace

// ======================================================================= API ==

extern "C" {

const char *sk_last_error(void) { return g_error.c_str(); }

void sk_release(SKHandle h) {
  std::lock_guard<std::mutex> lock(g_mutex);
  g_objects.erase(h);
}

// ---------------------------------------------------------------- sketches ---

SKHandle sk_sketch_new(SKFrame frame) {
  SK_TRY
  Sketch s;
  s.frame = toAx3(frame);
  return store(std::move(s));
  SK_CATCH(0)
}

static bool addCurve(SKHandle sketch, const char *tag, const TopoDS_Shape &edge) {
  Sketch *s;
  auto keep = lookup(sketch, s);
  if (!s) return false;
  s->curves.push_back({edge, tag ? tag : ""});
  s->regions.clear();
  return true;
}

bool sk_sketch_add_line(SKHandle sketch, const char *tag, double u1, double v1, double u2, double v2) {
  SK_TRY
  Sketch *s;
  auto keep = lookup(sketch, s);
  if (!s) return false;
  BRepBuilderAPI_MakeEdge mk(frameToWorld(s->frame, u1, v1), frameToWorld(s->frame, u2, v2));
  if (!mk.IsDone()) {
    setError("degenerate line");
    return false;
  }
  return addCurve(sketch, tag, mk.Edge());
  SK_CATCH(false)
}

static TopoDS_Edge circleEdge(const gp_Ax3 &frame, double cu, double cv, double r, const double *a0, const double *a1) {
  gp_Ax2 ax(frameToWorld(frame, cu, cv), frame.Direction(), frame.XDirection());
  gp_Circ c(ax, r);
  return a0 ? BRepBuilderAPI_MakeEdge(c, *a0, *a1).Edge() : BRepBuilderAPI_MakeEdge(c).Edge();
}

bool sk_sketch_add_circle(SKHandle sketch, const char *tag, double cu, double cv, double r) {
  SK_TRY
  Sketch *s;
  auto keep = lookup(sketch, s);
  if (!s) return false;
  if (r <= Precision::Confusion()) {
    setError("circle radius must be positive");
    return false;
  }
  return addCurve(sketch, tag, circleEdge(s->frame, cu, cv, r, nullptr, nullptr));
  SK_CATCH(false)
}

bool sk_sketch_add_arc(SKHandle sketch, const char *tag, double cu, double cv, double r, double a0, double a1) {
  SK_TRY
  Sketch *s;
  auto keep = lookup(sketch, s);
  if (!s) return false;
  if (r <= Precision::Confusion()) {
    setError("arc radius must be positive");
    return false;
  }
  while (a1 <= a0) a1 += 2 * M_PI;
  return addCurve(sketch, tag, circleEdge(s->frame, cu, cv, r, &a0, &a1));
  SK_CATCH(false)
}

int sk_sketch_build_regions(SKHandle sketch) {
  SK_TRY
  Sketch *s;
  auto keep = lookup(sketch, s);
  if (!s) return -1;
  s->regions.clear();
  s->pieces.clear();
  if (s->curves.empty()) return 0;

  const double big = 1e5;
  TopoDS_Face base = BRepBuilderAPI_MakeFace(gp_Pln(s->frame), -big, big, -big, big).Face();
  BRepAlgoAPI_Splitter sp;
  ShapeList args, tools;
  args.Append(base);
  for (const Named &c : s->curves) tools.Append(c.shape);
  sp.SetArguments(args);
  sp.SetTools(tools);
  sp.SetFuzzyValue(1e-6);  // glue endpoints that the solver left a hair apart
  sp.Build();
  if (!sp.IsDone() || sp.HasErrors()) {
    setError("could not split sketch plane into regions");
    return -1;
  }
  for (const Named &c : s->curves) {
    const ShapeList &mods = sp.Modified(c.shape);
    if (mods.IsEmpty())
      s->pieces.push_back(c);
    else
      for (const TopoDS_Shape &p : mods) s->pieces.push_back({p, c.name});
  }

  for (TopExp_Explorer fx(sp.Shape(), TopAbs_FACE); fx.More(); fx.Next()) {
    const TopoDS_Face &f = TopoDS::Face(fx.Current());
    std::vector<std::string> tags;
    bool outside = false;
    for (TopExp_Explorer ex(f, TopAbs_EDGE); ex.More() && !outside; ex.Next()) {
      auto it = std::find_if(s->pieces.begin(), s->pieces.end(),
                             [&](const Named &p) { return p.shape.IsSame(ex.Current()); });
      if (it == s->pieces.end())
        outside = true;  // touches the big base face's border
      else
        tags.push_back(it->name);
    }
    if (outside) continue;
    std::sort(tags.begin(), tags.end());
    tags.erase(std::unique(tags.begin(), tags.end()), tags.end());

    Sketch::Region r;
    r.face = f;
    for (size_t k = 0; k < tags.size(); ++k) r.tags += (k ? "," : "") + tags[k];
    GProp_GProps props;
    BRepGProp::SurfaceProperties(f, props);
    r.area = props.Mass();

    // Sample point: centroid of the largest triangle of a coarse mesh (always inside).
    BRepMesh_IncrementalMesh(f, std::sqrt(r.area) * 0.05, false, 0.5, false);
    TopLoc_Location loc;
    Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(f, loc);
    double best = -1;
    gp_Pnt sample = props.CentreOfMass();
    if (!tri.IsNull()) {
      for (int t = 1; t <= tri->NbTriangles(); ++t) {
        int a, b, c;
        tri->Triangle(t).Get(a, b, c);
        gp_Pnt pa = tri->Node(a), pb = tri->Node(b), pc = tri->Node(c);
        double area = gp_Vec(pa, pb).Crossed(gp_Vec(pa, pc)).Magnitude();
        if (area > best) {
          best = area;
          sample = gp_Pnt((pa.XYZ() + pb.XYZ() + pc.XYZ()) / 3.0).Transformed(loc.Transformation());
        }
      }
    }
    BRepTools::Clean(f);  // don't leave the coarse sampling mesh on a face that gets extruded
    gp_Vec d(s->frame.Location(), sample);
    r.u = d.Dot(gp_Vec(s->frame.XDirection()));
    r.v = d.Dot(gp_Vec(s->frame.YDirection()));
    s->regions.push_back(r);
  }
  return (int)s->regions.size();
  SK_CATCH(-1)
}

static const Sketch::Region *region(SKHandle sketch, int i, std::shared_ptr<Object> &keep) {
  Sketch *s;
  keep = lookup(sketch, s);
  if (!s) return nullptr;
  if (i < 0 || i >= (int)s->regions.size()) {
    setError("region index out of range");
    return nullptr;
  }
  return &s->regions[i];
}

const char *sk_sketch_region_tags(SKHandle sketch, int i) {
  std::shared_ptr<Object> keep;
  auto r = region(sketch, i, keep);
  return r ? r->tags.c_str() : nullptr;
}

double sk_sketch_region_area(SKHandle sketch, int i) {
  std::shared_ptr<Object> keep;
  auto r = region(sketch, i, keep);
  return r ? r->area : 0;
}

bool sk_sketch_region_sample(SKHandle sketch, int i, double *u, double *v) {
  std::shared_ptr<Object> keep;
  auto r = region(sketch, i, keep);
  if (!r) return false;
  *u = r->u;
  *v = r->v;
  return true;
}

SKHandle sk_sketch_region_profile(SKHandle sketch, int i) {
  SK_TRY
  std::shared_ptr<Object> keep;
  auto r = region(sketch, i, keep);
  if (!r) return 0;
  Sketch *s = std::get_if<Sketch>(keep.get());
  Profile p;
  p.face = r->face;
  for (TopExp_Explorer ex(r->face, TopAbs_EDGE); ex.More(); ex.Next())
    for (const Named &piece : s->pieces)
      if (piece.shape.IsSame(ex.Current())) {
        p.edgeTags.push_back({ex.Current(), piece.name});
        break;
      }
  return store(std::move(p));
  SK_CATCH(0)
}

// ---------------------------------------------------------------- features ---

SKHandle sk_extrude(const SKHandle *profiles, int count, double dx, double dy, double dz, double distance,
                    double distanceBack, const char *featureId) {
  SK_TRY
  const std::string feat = featureOrDefault(featureId, "extrude");
  const double length = distance + distanceBack;
  if (count < 1) {
    setError("extrude needs at least one profile");
    return 0;
  }
  if (std::fabs(length) <= Precision::Confusion()) {
    setError("extrude length is zero");
    return 0;
  }
  gp_Dir dir(dx, dy, dz);
  gp_Trsf shift;
  shift.SetTranslation(gp_Vec(dir) * -distanceBack);
  TopLoc_Location loc(shift);

  std::vector<TopoDS_Shape> solids;
  std::vector<Named> names;
  for (int k = 0; k < count; ++k) {
    Profile *p;
    auto keep = lookup(profiles[k], p);
    if (!p) return 0;
    TopoDS_Face f = TopoDS::Face(p->face.Moved(loc));
    BRepPrimAPI_MakePrism prism(f, gp_Vec(dir) * length);
    prism.Build();
    if (!prism.IsDone()) {
      setError("extrude failed");
      return 0;
    }
    // Negative length flips which cap is which; keep "start" at the -distanceBack end.
    names.push_back({prism.FirstShape(), feat + (length > 0 ? ".start" : ".end")});
    names.push_back({prism.LastShape(), feat + (length > 0 ? ".end" : ".start")});
    for (TopExp_Explorer ex(f, TopAbs_EDGE); ex.More(); ex.Next()) {
      std::string tag = "?";
      for (const Named &t : p->edgeTags)
        if (t.shape.Moved(loc).IsSame(ex.Current())) {
          tag = t.name;
          break;
        }
      for (const TopoDS_Shape &side : prism.Generated(ex.Current())) names.push_back({side, feat + ".side." + tag});
    }
    solids.push_back(prism.Shape());
  }

  TopoDS_Shape result = solids[0];
  if (solids.size() > 1) {
    BRepAlgoAPI_Fuse fuse;
    ShapeList args, tools;
    args.Append(solids[0]);
    for (size_t k = 1; k < solids.size(); ++k) tools.Append(solids[k]);
    fuse.SetArguments(args);
    fuse.SetTools(tools);
    fuse.Build();
    if (!fuse.IsDone() || fuse.HasErrors()) {
      setError("could not merge extruded profiles");
      return 0;
    }
    std::vector<Named> carried;
    carry(fuse, names, carried);
    names = std::move(carried);
    result = unify(fuse.Shape(), names);
  }
  return store(makeBody(result, names, feat));
  SK_CATCH(0)
}

SKHandle sk_boolean(SKHandle target, SKHandle tool, SKBooleanOp op) {
  SK_TRY
  Body *a, *b;
  auto keepA = lookup(target, a);
  auto keepB = lookup(tool, b);
  if (!a || !b) return 0;
  std::unique_ptr<BRepAlgoAPI_BooleanOperation> bop;
  switch (op) {
    case SK_FUSE: bop = std::make_unique<BRepAlgoAPI_Fuse>(a->shape, b->shape); break;
    case SK_CUT: bop = std::make_unique<BRepAlgoAPI_Cut>(a->shape, b->shape); break;
    case SK_COMMON: bop = std::make_unique<BRepAlgoAPI_Common>(a->shape, b->shape); break;
  }
  if (!bop->IsDone() || bop->HasErrors()) {
    setError("boolean operation failed");
    return 0;
  }
  std::vector<Named> names;
  carry(*bop, namedFaces(*a), names);  // target names first: they win on merged faces
  carry(*bop, namedFaces(*b), names);
  TopoDS_Shape result = unify(bop->Shape(), names);
  return store(makeBody(result, names, "boolean"));
  SK_CATCH(0)
}

SKHandle sk_fillet(SKHandle body, const char *const *edgeNames, int count, double radius, const char *featureId) {
  SK_TRY
  if (radius <= Precision::Confusion()) {
    setError("fillet radius must be positive");
    return 0;
  }
  return edgeFeature<BRepFilletAPI_MakeFillet>(body, edgeNames, count, featureOrDefault(featureId, "fillet"), "fillet",
                                               [&](BRepFilletAPI_MakeFillet &mk, const TopoDS_Edge &e) { mk.Add(radius, e); });
  SK_CATCH(0)
}

SKHandle sk_chamfer(SKHandle body, const char *const *edgeNames, int count, double distance, const char *featureId) {
  SK_TRY
  if (distance <= Precision::Confusion()) {
    setError("chamfer distance must be positive");
    return 0;
  }
  return edgeFeature<BRepFilletAPI_MakeChamfer>(
      body, edgeNames, count, featureOrDefault(featureId, "chamfer"), "chamfer",
      [&](BRepFilletAPI_MakeChamfer &mk, const TopoDS_Edge &e) { mk.Add(distance, e); });
  SK_CATCH(0)
}

// ----------------------------------------------------------------- queries ---

int sk_body_face_count(SKHandle body) {
  Body *b;
  auto keep = lookup(body, b);
  return b ? (int)b->faceNames.size() : -1;
}

const char *sk_body_face_name(SKHandle body, int i) {
  Body *b;
  auto keep = lookup(body, b);
  return (b && i >= 0 && i < (int)b->faceNames.size()) ? b->faceNames[i].c_str() : nullptr;
}

int sk_body_edge_count(SKHandle body) {
  Body *b;
  auto keep = lookup(body, b);
  return b ? (int)b->edgeNames.size() : -1;
}

const char *sk_body_edge_name(SKHandle body, int i) {
  Body *b;
  auto keep = lookup(body, b);
  return (b && i >= 0 && i < (int)b->edgeNames.size()) ? b->edgeNames[i].c_str() : nullptr;
}

int sk_body_find_face(SKHandle body, const char *name) {
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return -1;
  auto it = b->faceIndex.find(name);
  return it == b->faceIndex.end() ? -1 : it->second;
}

int sk_body_find_edge(SKHandle body, const char *name) {
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return -1;
  auto it = b->edgeIndex.find(name);
  return it == b->edgeIndex.end() ? -1 : it->second;
}

bool sk_body_face_frame(SKHandle body, const char *faceName, SKFrame *out) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return false;
  auto it = b->faceIndex.find(faceName);
  if (it == b->faceIndex.end()) {
    setError(std::string("face not found: ") + faceName);
    return false;
  }
  const TopoDS_Face &f = TopoDS::Face(b->faces(it->second + 1));
  BRepAdaptor_Surface s(f);
  if (s.GetType() != GeomAbs_Plane) {
    setError(std::string("face is not planar: ") + faceName);
    return false;
  }
  gp_Ax3 pos = s.Plane().Position();
  gp_Dir n = pos.Direction();
  if (f.Orientation() == TopAbs_REVERSED) n.Reverse();
  const gp_Pnt &o = pos.Location();
  const gp_Dir &x = pos.XDirection();
  *out = SKFrame{o.X(), o.Y(), o.Z(), n.X(), n.Y(), n.Z(), x.X(), x.Y(), x.Z()};
  return true;
  SK_CATCH(false)
}

double sk_body_volume(SKHandle body) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return 0;
  GProp_GProps props;
  BRepGProp::VolumeProperties(b->shape, props);
  return props.Mass();
  SK_CATCH(0)
}

bool sk_body_bounds(SKHandle body, double out[6]) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return false;
  Bnd_Box box;
  BRepBndLib::Add(b->shape, box);
  if (box.IsVoid()) return false;
  box.Get(out[0], out[1], out[2], out[3], out[4], out[5]);
  return true;
  SK_CATCH(false)
}

bool sk_body_is_valid(SKHandle body) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  return b && BRepCheck_Analyzer(b->shape).IsValid();
  SK_CATCH(false)
}

// ------------------------------------------------------------ tessellation ---

SKMesh *sk_body_tessellate(SKHandle body, double linearDeflection, double angularDeflection) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return nullptr;
  BRepMesh_IncrementalMesh mesher(b->shape, linearDeflection, false, angularDeflection, true);

  std::vector<float> pos, nrm, seg;
  std::vector<uint32_t> idx, triFace, segEdge;
  for (int i = 1; i <= b->faces.Extent(); ++i)
    appendFace(TopoDS::Face(b->faces(i)), (uint32_t)(i - 1), pos, nrm, idx, triFace);
  for (int j = 1; j <= b->edges.Extent(); ++j) {
    if (b->edgeHidden[j - 1]) continue;
    BRepAdaptor_Curve c(TopoDS::Edge(b->edges(j)));
    GCPnts_TangentialDeflection d(c, angularDeflection, linearDeflection);
    for (int k = 1; k < d.NbPoints(); ++k) {
      gp_Pnt p = d.Value(k), q = d.Value(k + 1);
      seg.insert(seg.end(), {(float)p.X(), (float)p.Y(), (float)p.Z(), (float)q.X(), (float)q.Y(), (float)q.Z()});
      segEdge.push_back((uint32_t)(j - 1));
    }
  }

  return packMesh(pos, nrm, idx, triFace, seg, segEdge);
  SK_CATCH(nullptr)
}

SKMesh *sk_sketch_region_tessellate(SKHandle sketch, int i, double linearDeflection) {
  SK_TRY
  std::shared_ptr<Object> keep;
  auto r = region(sketch, i, keep);
  if (!r) return nullptr;
  TopoDS_Face f = TopoDS::Face(BRepBuilderAPI_Copy(r->face).Shape());  // mesh a copy, keep the profile clean
  BRepMesh_IncrementalMesh mesher(f, linearDeflection, false, 0.35, false);
  std::vector<float> pos, nrm, seg;
  std::vector<uint32_t> idx, triFace, segEdge;
  appendFace(f, 0, pos, nrm, idx, triFace);
  return packMesh(pos, nrm, idx, triFace, seg, segEdge);
  SK_CATCH(nullptr)
}

void sk_mesh_free(SKMesh *m) {
  if (!m) return;
  std::free(m->positions);
  std::free(m->normals);
  std::free(m->indices);
  std::free(m->triangleFace);
  std::free(m->segments);
  std::free(m->segmentEdge);
  std::free(m);
}

// ------------------------------------------------------------------ export ---

static bool compoundOf(const SKHandle *bodies, int count, TopoDS_Compound &out) {
  BRep_Builder bb;
  bb.MakeCompound(out);
  for (int k = 0; k < count; ++k) {
    Body *b;
    auto keep = lookup(bodies[k], b);
    if (!b) return false;
    bb.Add(out, b->shape);
  }
  return true;
}

bool sk_export_step(const SKHandle *bodies, int count, const char *path) {
  SK_TRY
  TopoDS_Compound comp;
  if (!compoundOf(bodies, count, comp)) return false;
  static const bool quiet = [] {  // OCCT's data-exchange code prints statistics to stdout
    Message::DefaultMessenger()->RemovePrinters(STANDARD_TYPE(Message_PrinterOStream));
    return true;
  }();
  (void)quiet;
  STEPControl_Writer w;
  if (w.Transfer(comp, STEPControl_AsIs) != IFSelect_RetDone || w.Write(path) != IFSelect_RetDone) {
    setError(std::string("STEP export failed: ") + path);
    return false;
  }
  return true;
  SK_CATCH(false)
}

bool sk_export_stl(const SKHandle *bodies, int count, const char *path, double linearDeflection) {
  SK_TRY
  TopoDS_Compound comp;
  if (!compoundOf(bodies, count, comp)) return false;
  BRepMesh_IncrementalMesh mesher(comp, linearDeflection, false, 0.3, true);
  if (!StlAPI_Writer().Write(comp, path)) {
    setError(std::string("STL export failed: ") + path);
    return false;
  }
  return true;
  SK_CATCH(false)
}

}  // extern "C"
