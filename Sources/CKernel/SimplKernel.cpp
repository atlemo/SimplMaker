// SimplKernel — OpenCASCADE implementation of the C API in include/SimplKernel.h.
// SPDX-License-Identifier: GPL-3.0-or-later

#include "SimplKernel.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <sstream>
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
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepBuilderAPI_MakeVertex.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepBuilderAPI_MakeSolid.hxx>
#include <BRepBuilderAPI_Sewing.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepFeat_MakeLinearForm.hxx>
#include <BRepLib.hxx>
#include <BRepOffsetAPI_MakePipe.hxx>
#include <BRepOffsetAPI_MakePipeShell.hxx>
#include <BRepOffsetAPI_ThruSections.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <BRepPrimAPI_MakeTorus.hxx>
#include <BRepTools_WireExplorer.hxx>
#include <Geom2d_Line.hxx>
#include <Geom_BezierCurve.hxx>
#include <NCollection_Array1.hxx>
#include <Geom_CylindricalSurface.hxx>
#include <Geom_Plane.hxx>
#include <TopoDS_Wire.hxx>
#include <BRepBndLib.hxx>
#include <BRepOffsetAPI_MakeThickSolid.hxx>
#include <BRepClass_FaceClassifier.hxx>
#include <BRepBuilderAPI_Copy.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepClass3d_SolidClassifier.hxx>
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
#include <Geom2d_Curve.hxx>
#include <GeomAPI_ProjectPointOnSurf.hxx>
#include <GCPnts_TangentialDeflection.hxx>
#include <GProp_GProps.hxx>
#include <GeomAbs_SurfaceType.hxx>
#include <Message.hxx>
#include <Message_Messenger.hxx>
#include <Message_PrinterOStream.hxx>
#include <Poly_Triangulation.hxx>
#include <STEPControl_Reader.hxx>
#include <STEPControl_Writer.hxx>
#include <ShapeFix_Shape.hxx>
#include <ShapeUpgrade_UnifySameDomain.hxx>
#include <Standard_Failure.hxx>
#include <Standard_Version.hxx>
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
#include <TopoDS_Shell.hxx>
#include <TopoDS_Solid.hxx>
#include <gp_Ax2.hxx>
#include <gp_Ax3.hxx>
#include <gp_Circ.hxx>
#include <gp_Cylinder.hxx>
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

/// A connected chain of sketch curves (for sweeps, pipes and ribs), with its sketch plane.
struct Path {
  TopoDS_Wire wire;
  gp_Ax3 frame;
};

using Object = std::variant<Body, Profile, Sketch, Path>;

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

/// Tag of the sketch curve a profile edge came from ("?" if unknown).
std::string edgeTag(const Profile &p, const TopoDS_Shape &edge) {
  for (const Named &t : p.edgeTags)
    if (t.shape.IsSame(edge)) return t.name;
  return "?";
}

/// Names the side faces an operation generated from a profile's edges.
template <class Op>
void nameSides(Op &op, const Profile &p, const std::string &feat, std::vector<Named> &names) {
  for (TopExp_Explorer ex(p.face, TopAbs_EDGE); ex.More(); ex.Next())
    for (const TopoDS_Shape &g : op.Generated(ex.Current()))
      if (g.ShapeType() == TopAbs_FACE) names.push_back({g, feat + ".side." + edgeTag(p, ex.Current())});
}

/// Some operations report no history for some edges (a revolve's edges square to the axis). The face
/// an edge sweeps still contains the edge where the sweep starts, so name leftover faces by that.
void nameSidesByContact(const TopoDS_Shape &shape, const Profile &p, const std::string &feat, std::vector<Named> &names) {
  for (TopExp_Explorer fx(shape, TopAbs_FACE); fx.More(); fx.Next()) {
    const TopoDS_Shape &f = fx.Current();
    bool named = false;
    for (const Named &n : names)
      if (n.shape.IsSame(f)) named = true;
    if (named) continue;
    for (TopExp_Explorer ex(p.face, TopAbs_EDGE); ex.More(); ex.Next()) {
      BRepAdaptor_Curve c(TopoDS::Edge(ex.Current()));
      const gp_Pnt mid = c.Value(0.5 * (c.FirstParameter() + c.LastParameter()));
      BRepExtrema_DistShapeShape d(BRepBuilderAPI_MakeVertex(mid).Vertex(), f);
      if (d.IsDone() && d.Value() < 1e-6) {
        names.push_back({f, feat + ".side." + edgeTag(p, ex.Current())});
        break;
      }
    }
  }
}

/// Looks up profile handles; false (with the error set) if any is invalid.
bool profilesOf(const SKHandle *handles, int count, std::vector<std::shared_ptr<Object>> &keep,
                std::vector<Profile *> &out, const char *what) {
  if (count < 1) {
    setError(std::string(what) + " needs at least one profile");
    return false;
  }
  for (int k = 0; k < count; ++k) {
    Profile *p;
    keep.push_back(lookup(handles[k], p));
    if (!p) return false;
    out.push_back(p);
  }
  return true;
}

/// Fuses the solids of one feature into a single shape, carrying names.
bool fuseAll(const std::vector<TopoDS_Shape> &solids, std::vector<Named> &names, TopoDS_Shape &result) {
  result = solids[0];
  if (solids.size() == 1) return true;
  BRepAlgoAPI_Fuse fuse;
  ShapeList args, tools;
  args.Append(solids[0]);
  for (size_t k = 1; k < solids.size(); ++k) tools.Append(solids[k]);
  fuse.SetArguments(args);
  fuse.SetTools(tools);
  fuse.Build();
  if (!fuse.IsDone() || fuse.HasErrors()) {
    setError("could not merge the profiles' solids");
    return false;
  }
  std::vector<Named> carried;
  carry(fuse, names, carried);
  names = std::move(carried);
  result = unify(fuse.Shape(), names);
  return true;
}

/// Stores a body after checking it is a valid solid.
SKHandle storeChecked(const TopoDS_Shape &shape, const std::vector<Named> &names, const std::string &feat,
                      const char *failure) {
  Body b = makeBody(shape, names, feat);
  if (!BRepCheck_Analyzer(b.shape).IsValid()) {
    setError(failure);
    return 0;
  }
  return store(std::move(b));
}

/// Names unnamed faces by where they face in `frame`: top/bottom (along the normal),
/// right/left (x), back/front (y); curved or slanted faces are "side".
void nameByDirection(const TopoDS_Shape &shape, const gp_Ax3 &frame, const std::string &feat, std::vector<Named> &names) {
  for (TopExp_Explorer ex(shape, TopAbs_FACE); ex.More(); ex.Next()) {
    const TopoDS_Face &f = TopoDS::Face(ex.Current());
    bool named = false;
    for (const Named &n : names)
      if (n.shape.IsSame(f)) named = true;
    if (named) continue;
    std::string side = "side";
    BRepAdaptor_Surface s(f);
    if (s.GetType() == GeomAbs_Plane) {
      gp_Dir d = s.Plane().Axis().Direction();
      if (f.Orientation() == TopAbs_REVERSED) d.Reverse();
      const double z = d.Dot(frame.Direction()), x = d.Dot(frame.XDirection()), y = d.Dot(frame.YDirection());
      if (z > 0.999) side = "top";
      else if (z < -0.999) side = "bottom";
      else if (x > 0.999) side = "right";
      else if (x < -0.999) side = "left";
      else if (y > 0.999) side = "back";
      else if (y < -0.999) side = "front";
    }
    names.push_back({f, feat + "." + side});
  }
}

/// Start point and unit tangent of a wire, following its edge order.
bool wireStart(const TopoDS_Wire &w, gp_Pnt &p, gp_Vec &t) {
  BRepTools_WireExplorer ex(w);
  if (!ex.More()) return false;
  const TopoDS_Edge &e = ex.Current();
  BRepAdaptor_Curve c(e);
  const bool rev = e.Orientation() == TopAbs_REVERSED;
  c.D1(rev ? c.LastParameter() : c.FirstParameter(), p, t);
  if (rev) t.Reverse();
  if (t.Magnitude() < 1e-12) return false;
  t.Normalize();
  return true;
}

/// Sweeps a circle of `radius` along `spine`, starting perpendicular to it at its start.
/// Names: <feat>.start / .end for the caps, <feat>.<surface> for the swept face.
bool sweepCircle(const TopoDS_Wire &spine, double radius, bool frenet, const std::string &feat,
                 const std::string &surface, TopoDS_Shape &out, std::vector<Named> &names) {
  gp_Pnt p;
  gp_Vec t;
  if (!wireStart(spine, p, t)) {
    setError("the path is empty or degenerate");
    return false;
  }
  TopoDS_Edge circle = BRepBuilderAPI_MakeEdge(gp_Circ(gp_Ax2(p, gp_Dir(t)), radius)).Edge();
  TopoDS_Wire section = BRepBuilderAPI_MakeWire(circle).Wire();
  BRepOffsetAPI_MakePipeShell pipe(spine);
  pipe.SetMode(frenet);
  pipe.SetTransitionMode(BRepBuilderAPI_RoundCorner);  // sharp corners in the path become rounded elbows
  pipe.Add(section);
  pipe.Build();
  if (!pipe.IsDone() || !pipe.MakeSolid()) {
    setError("the sweep failed (does the path turn too tightly for the diameter?)");
    return false;
  }
  out = pipe.Shape();
  names.push_back({pipe.FirstShape(), feat + ".start"});
  names.push_back({pipe.LastShape(), feat + ".end"});
  for (const TopoDS_Shape &g : pipe.Generated(circle))
    if (g.ShapeType() == TopAbs_FACE) names.push_back({g, feat + "." + surface});
  return true;
}


/// A round face: the axis from the end a thread starts at (`start`, going along `dir`), its radius
/// and length, whether it's a hole (material outside it), and whether there's air beyond each end.
struct Cylinder {
  gp_Pnt start;
  gp_Dir dir;
  gp_Dir radial;  // from the axis towards a point in the middle of the face
  double radius = 0, length = 0;
  bool internal = false, freeStart = false, freeEnd = false;
};

/// Works out a round face's Cylinder. A thread starts at an end with air beyond it (the tip of a
/// shaft, the mouth of a hole), else at the end its axis points to; `flipped` takes the other end.
bool cylinderOf(const Body &b, const TopoDS_Face &face, bool flipped, Cylinder &out) {
  BRepAdaptor_Surface s(face);
  if (s.GetType() != GeomAbs_Cylinder) {
    setError("a thread needs a round face: the side of a shaft or the wall of a hole");
    return false;
  }
  const gp_Cylinder cyl = s.Cylinder();
  const gp_Pnt origin = cyl.Axis().Location();
  gp_Dir d = cyl.Axis().Direction();
  double u0, u1, v0, v1;
  BRepTools::UVBounds(face, u0, u1, v0, v1);
  if (u1 - u0 < M_PI - 1e-6) {  // a fillet along a straight edge, say
    setError("a thread needs a face that goes round (a shaft or a hole), not part of one");
    return false;
  }
  gp_Pnt p;
  gp_Vec du, dv;
  s.D1((u0 + u1) / 2, (v0 + v1) / 2, p, du, dv);
  gp_Vec n = du.Crossed(dv);
  if (face.Orientation() == TopAbs_REVERSED) n.Reverse();
  const gp_Pnt mid = origin.Translated(gp_Vec(d) * ((v0 + v1) / 2));
  const gp_Vec toFace(mid, p);
  if (toFace.Magnitude() < Precision::Confusion()) {
    setError("the round face is degenerate");
    return false;
  }
  out.radial = gp_Dir(toFace);
  out.radius = cyl.Radius();
  out.length = std::abs(v1 - v0);
  out.internal = n.Dot(toFace) < 0;  // the face looks towards the axis: a hole

  gp_Pnt lo = origin.Translated(gp_Vec(d) * std::min(v0, v1)), hi = origin.Translated(gp_Vec(d) * std::max(v0, v1));
  // The same end for the same face however the kernel happened to orient its axis.
  const double c[3] = {d.X(), d.Y(), d.Z()};
  int big = 0;
  for (int k = 1; k < 3; ++k)
    if (std::abs(c[k]) > std::abs(c[big]) + 1e-9) big = k;
  if (c[big] < 0) {
    d.Reverse();
    std::swap(lo, hi);
  }
  // Air just beyond an end, at a radius inside the thread's reach: a hole's mouth, a shaft's tip.
  const double probeRadius = out.radius * (out.internal ? 1.1 : 0.75);
  auto isFree = [&](const gp_Pnt &end, const gp_Vec &outward) {
    const gp_Pnt q = end.Translated(gp_Vec(out.radial) * probeRadius + outward * (0.1 * out.radius));
    BRepClass3d_SolidClassifier probe(b.shape, q, 1e-7);
    return probe.State() == TopAbs_OUT;
  };
  const bool freeHi = isFree(hi, gp_Vec(d)), freeLo = isFree(lo, -gp_Vec(d));
  bool fromHi = freeHi || !freeLo;
  if (flipped) fromHi = !fromHi;
  out.start = fromHi ? hi : lo;
  out.dir = fromHi ? d.Reversed() : d;
  out.freeStart = fromHi ? freeHi : freeLo;
  out.freeEnd = fromHi ? freeLo : freeHi;
  return true;
}

/// A solid of revolution about the frame's normal from a closed (radius, height) outline.
TopoDS_Shape revolved(const gp_Ax3 &f, const std::vector<std::pair<double, double>> &rz) {
  BRepBuilderAPI_MakePolygon poly;
  for (auto &[r, z] : rz) poly.Add(f.Location().Translated(gp_Vec(f.XDirection()) * r + gp_Vec(f.Direction()) * z));
  poly.Close();
  TopoDS_Face face = BRepBuilderAPI_MakeFace(poly.Wire(), true).Face();
  return BRepPrimAPI_MakeRevol(face, gp_Ax1(f.Location(), f.Direction())).Shape();
}

/// A ring between two radii from height z0 to z1 (a solid cylinder when rIn is 0).
TopoDS_Shape ring(const gp_Ax3 &f, double rIn, double rOut, double z0, double z1) {
  return revolved(f, {{rIn, z0}, {rOut, z0}, {rOut, z1}, {rIn, z1}});
}

/// A boolean on a shape and its face names, carrying the names of both operands.
bool namedBoolean(TopoDS_Shape &shape, std::vector<Named> &names, const TopoDS_Shape &tool, const std::string &toolName,
                  SKBooleanOp op) {
  std::unique_ptr<BRepAlgoAPI_BooleanOperation> bop;
  switch (op) {
    case SK_FUSE: bop = std::make_unique<BRepAlgoAPI_Fuse>(); break;
    case SK_CUT: bop = std::make_unique<BRepAlgoAPI_Cut>(); break;
    case SK_COMMON: bop = std::make_unique<BRepAlgoAPI_Common>(); break;
  }
  ShapeList args, tools;
  args.Append(shape);
  tools.Append(tool);
  bop->SetArguments(args);
  bop->SetTools(tools);
  bop->SetRunParallel(true);
  bop->Build();
  if (!bop->IsDone() || bop->HasErrors()) return false;
  std::vector<Named> toolNames, out;
  for (TopExp_Explorer ex(tool, TopAbs_FACE); ex.More(); ex.Next()) toolNames.push_back({ex.Current(), toolName});
  carry(*bop, names, out);  // the body's names first: they win on merged faces
  carry(*bop, toolNames, out);
  shape = bop->Shape();
  names = std::move(out);
  return true;
}

/// The solid swept by a thread's groove profile along a helix about the frame's normal, from
/// height z0 to z1: one edge per turn (a single long helix edge approximates poorly).
bool helicalSweep(const gp_Ax3 &f, double pitch, double z0, double z1, bool leftHanded,
                  const std::vector<std::pair<double, double>> &profile, TopoDS_Shape &out) {
  const double radius = profile.front().first;
  const int turns = std::max(1, (int)std::ceil((z1 - z0) / pitch));
  gp_Ax3 base(f.Location().Translated(gp_Vec(f.Direction()) * z0), f.Direction(), f.XDirection());
  Handle(Geom_CylindricalSurface) cyl = new Geom_CylindricalSurface(base, radius);
  Handle(Geom2d_Line) line = new Geom2d_Line(gp_Pnt2d(0, 0), gp_Dir2d(leftHanded ? -2 * M_PI : 2 * M_PI, pitch));
  const double perTurn = std::hypot(2 * M_PI, pitch);
  BRepBuilderAPI_MakeWire wire;
  for (int k = 0; k < turns; ++k) {
    TopoDS_Edge e = BRepBuilderAPI_MakeEdge(line, cyl, k * perTurn, (k + 1) * perTurn).Edge();
    BRepLib::BuildCurves3d(e, 1e-6, GeomAbs_C1, 14, 50);
    wire.Add(e);
  }
  if (!wire.IsDone()) return false;
  // The profile in the plane through the axis and the helix's start (u = 0, height z0).
  BRepBuilderAPI_MakePolygon poly;
  for (auto &[r, z] : profile) poly.Add(base.Location().Translated(gp_Vec(base.XDirection()) * r + gp_Vec(base.Direction()) * z));
  poly.Close();
  BRepOffsetAPI_MakePipeShell pipe(wire.Wire());
  pipe.SetMode(f.Direction());  // keep the profile in a plane through the axis all the way round
  pipe.Add(poly.Wire());
  pipe.Build();
  if (!pipe.IsDone() || !pipe.MakeSolid()) return false;
  out = pipe.Shape();
  return true;
}

}  // namespace

// ======================================================================= API ==

extern "C" {

const char *sk_last_error(void) { return g_error.c_str(); }
const char *sk_occt_version(void) { return OCC_VERSION_COMPLETE; }

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

bool sk_sketch_add_bezier(SKHandle sketch, const char *tag, const double *uv, int count) {
  SK_TRY
  Sketch *s;
  auto keep = lookup(sketch, s);
  if (!s) return false;
  if (count < 2 || count > 25) {
    setError("a Bézier curve needs 2 to 25 control points");
    return false;
  }
  NCollection_Array1<gp_Pnt> poles(1, count);
  for (int k = 0; k < count; ++k) poles(k + 1) = frameToWorld(s->frame, uv[2 * k], uv[2 * k + 1]);
  if (poles(1).Distance(poles(count)) <= Precision::Confusion()) {
    setError("degenerate Bézier curve");
    return false;
  }
  Handle(Geom_BezierCurve) curve = new Geom_BezierCurve(poles);
  BRepBuilderAPI_MakeEdge mk(curve);
  if (!mk.IsDone()) {
    setError("could not make a Bézier edge");
    return false;
  }
  return addCurve(sketch, tag, mk.Edge());
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

bool sk_sketch_region_contains(SKHandle sketch, int i, double u, double v) {
  SK_TRY
  std::shared_ptr<Object> keep;
  auto r = region(sketch, i, keep);
  if (!r) return false;
  Sketch *s;
  auto keepSketch = lookup(sketch, s);
  if (!s) return false;
  BRepClass_FaceClassifier classifier(r->face, frameToWorld(s->frame, u, v), 1e-7);
  return classifier.State() == TopAbs_IN;
  SK_CATCH(false)
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
  // Pieces that don't touch (the letters of a text, say) need no merging: they go into the body
  // as they are, which is what merging would give, only much faster.
  bool touching = false;
  std::vector<Bnd_Box> boxes(solids.size());
  for (size_t k = 0; k < solids.size(); ++k) BRepBndLib::Add(solids[k], boxes[k]);
  for (size_t i = 0; i < solids.size() && !touching; ++i)
    for (size_t j = i + 1; j < solids.size() && !touching; ++j) {
      Bnd_Box bi = boxes[i];
      bi.Enlarge(1e-6);
      touching = !bi.IsOut(boxes[j]);
    }
  if (solids.size() > 1 && !touching) {
    TopoDS_Compound all;
    BRep_Builder bb;
    bb.MakeCompound(all);
    for (const TopoDS_Shape &sol : solids) bb.Add(all, sol);
    result = all;
  } else if (solids.size() > 1) {
    BRepAlgoAPI_Fuse fuse;
    ShapeList args, tools;
    args.Append(solids[0]);
    for (size_t k = 1; k < solids.size(); ++k) tools.Append(solids[k]);
    fuse.SetArguments(args);
    fuse.SetTools(tools);
    fuse.SetRunParallel(true);
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

SKHandle sk_revolve(const SKHandle *profiles, int count, double ox, double oy, double oz, double dx, double dy,
                    double dz, double angle, const char *featureId) {
  SK_TRY
  const std::string feat = featureOrDefault(featureId, "revolve");
  std::vector<std::shared_ptr<Object>> keep;
  std::vector<Profile *> ps;
  if (!profilesOf(profiles, count, keep, ps, "revolve")) return 0;
  if (angle <= Precision::Angular()) {
    setError("the revolve angle must be positive");
    return 0;
  }
  const gp_Ax1 axis(gp_Pnt(ox, oy, oz), gp_Dir(dx, dy, dz));
  const bool full = angle >= 2 * M_PI - 1e-9;
  std::vector<TopoDS_Shape> solids;
  std::vector<Named> names;
  for (Profile *p : ps) {
    std::unique_ptr<BRepPrimAPI_MakeRevol> rev = full ? std::make_unique<BRepPrimAPI_MakeRevol>(p->face, axis)
                                                       : std::make_unique<BRepPrimAPI_MakeRevol>(p->face, axis, angle);
    rev->Build();
    if (!rev->IsDone()) {
      setError("revolve failed (does the profile cross the axis?)");
      return 0;
    }
    if (!full) {
      names.push_back({rev->FirstShape(), feat + ".start"});
      names.push_back({rev->LastShape(), feat + ".end"});
    }
    nameSides(*rev, *p, feat, names);
    nameSidesByContact(rev->Shape(), *p, feat, names);
    solids.push_back(rev->Shape());
  }
  TopoDS_Shape result;
  if (!fuseAll(solids, names, result)) return 0;
  return storeChecked(result, names, feat, "revolve produced an invalid solid (does the profile cross the axis?)");
  SK_CATCH(0)
}

SKHandle sk_sketch_path(SKHandle sketch, const char *const *tags, int count) {
  SK_TRY
  Sketch *s;
  auto keep = lookup(sketch, s);
  if (!s) return 0;
  ShapeList edges;
  for (int k = 0; k < count; ++k)
    for (const Named &c : s->curves)
      if (c.name == tags[k]) edges.Append(c.shape);
  if (edges.IsEmpty()) {
    setError("the path has no curves");
    return 0;
  }
  BRepBuilderAPI_MakeWire mw;
  mw.Add(edges);
  if (!mw.IsDone()) {
    setError("the path curves must connect end to end without branching");
    return 0;
  }
  return store(Path{mw.Wire(), s->frame});
  SK_CATCH(0)
}

SKHandle sk_sweep(const SKHandle *profiles, int count, SKHandle path, const char *featureId) {
  SK_TRY
  const std::string feat = featureOrDefault(featureId, "sweep");
  std::vector<std::shared_ptr<Object>> keep;
  std::vector<Profile *> ps;
  if (!profilesOf(profiles, count, keep, ps, "sweep")) return 0;
  Path *pa;
  auto keepPath = lookup(path, pa);
  if (!pa) return 0;
  std::vector<TopoDS_Shape> solids;
  std::vector<Named> names;
  for (Profile *p : ps) {
    BRepOffsetAPI_MakePipe pipe(pa->wire, p->face);
    pipe.Build();
    if (!pipe.IsDone()) {
      setError("sweep failed (does the path turn too tightly for the profile?)");
      return 0;
    }
    names.push_back({pipe.FirstShape(), feat + ".start"});
    names.push_back({pipe.LastShape(), feat + ".end"});
    nameSides(pipe, *p, feat, names);
    nameSidesByContact(pipe.Shape(), *p, feat, names);
    solids.push_back(pipe.Shape());
  }
  TopoDS_Shape result;
  if (!fuseAll(solids, names, result)) return 0;
  return storeChecked(result, names, feat, "sweep produced an invalid solid (the profile may intersect itself along the path)");
  SK_CATCH(0)
}

SKHandle sk_pipe(SKHandle path, double diameter, double wall, const char *featureId) {
  SK_TRY
  const std::string feat = featureOrDefault(featureId, "pipe");
  Path *pa;
  auto keep = lookup(path, pa);
  if (!pa) return 0;
  if (diameter <= Precision::Confusion()) {
    setError("the pipe diameter must be positive");
    return 0;
  }
  if (wall < 0 || wall >= diameter / 2) {
    setError("the wall must be thinner than the pipe's radius");
    return 0;
  }
  TopoDS_Shape outer;
  std::vector<Named> names;
  if (!sweepCircle(pa->wire, diameter / 2, false, feat, "outer", outer, names)) return 0;
  if (wall <= Precision::Confusion()) return storeChecked(outer, names, feat, "the pipe is invalid");
  TopoDS_Shape inner;
  std::vector<Named> innerNames;
  if (!sweepCircle(pa->wire, diameter / 2 - wall, false, feat, "inner", inner, innerNames)) return 0;
  BRepAlgoAPI_Cut cut(outer, inner);
  if (!cut.IsDone() || cut.HasErrors()) {
    setError("could not hollow the pipe");
    return 0;
  }
  std::vector<Named> carried;
  carry(cut, names, carried);
  std::vector<Named> innerCarried;
  carry(cut, {innerNames.begin() + 2, innerNames.end()}, innerCarried);  // the bore, not the inner caps
  carried.insert(carried.end(), innerCarried.begin(), innerCarried.end());
  return storeChecked(cut.Shape(), carried, feat, "the hollow pipe is invalid");
  SK_CATCH(0)
}

SKHandle sk_loft(const SKHandle *profiles, int count, bool ruled, const char *featureId) {
  SK_TRY
  const std::string feat = featureOrDefault(featureId, "loft");
  std::vector<std::shared_ptr<Object>> keep;
  std::vector<Profile *> ps;
  if (!profilesOf(profiles, count, keep, ps, "loft")) return 0;
  if (count < 2) {
    setError("a loft needs at least two profiles");
    return 0;
  }
  BRepOffsetAPI_ThruSections loft(true, ruled);
  std::vector<TopoDS_Wire> wires;
  for (Profile *p : ps) {
    wires.push_back(BRepTools::OuterWire(p->face));
    loft.AddWire(wires.back());
  }
  loft.Build();
  if (!loft.IsDone()) {
    setError("loft failed (are the profiles far enough apart, and not crossing?)");
    return 0;
  }
  std::vector<Named> names{{loft.FirstShape(), feat + ".start"}, {loft.LastShape(), feat + ".end"}};
  for (TopExp_Explorer ex(wires[0], TopAbs_EDGE); ex.More(); ex.Next()) {
    TopoDS_Shape g = loft.GeneratedFace(ex.Current());
    if (!g.IsNull()) names.push_back({g, feat + ".side." + edgeTag(*ps[0], ex.Current())});
  }
  return storeChecked(loft.Shape(), names, feat, "loft produced an invalid solid");
  SK_CATCH(0)
}

SKHandle sk_rib(SKHandle body, SKHandle path, double thickness, const char *featureId) {
  SK_TRY
  const std::string feat = featureOrDefault(featureId, "rib");
  Body *b;
  auto keepBody = lookup(body, b);
  Path *pa;
  auto keepPath = lookup(path, pa);
  if (!b || !pa) return 0;
  if (thickness <= Precision::Confusion()) {
    setError("the rib thickness must be positive");
    return 0;
  }
  if (pa->wire.Closed()) {
    setError("a rib needs an open curve, not a closed shape");
    return 0;
  }
  Handle(Geom_Plane) plane = new Geom_Plane(pa->frame);
  const gp_Vec n = gp_Vec(pa->frame.Direction()) * (thickness / 2);
  BRepFeat_MakeLinearForm form(b->shape, pa->wire, plane, n, n.Reversed(), 1, true);
  form.Perform();
  if (!form.IsDone() || form.Shape().IsNull()) {
    setError("the rib must meet the body at both ends (draw it across a corner, on a plane through the body)");
    return 0;
  }
  std::vector<Named> names;
  carry(form, namedFaces(*b), names);
  TopoDS_Shape result = unify(form.Shape(), names);
  return storeChecked(result, names, feat + ".rib", "the rib produced an invalid solid");
  SK_CATCH(0)
}

SKHandle sk_hole(SKFrame at, SKHoleKind kind, double diameter, double depth, double tipAngle, double headDiameter,
                 double headDepth, double headAngle, const char *featureId) {
  SK_TRY
  const std::string feat = featureOrDefault(featureId, "hole") + ".hole";
  const double r = diameter / 2;
  if (r <= Precision::Confusion() || depth <= Precision::Confusion()) {
    setError("the hole diameter and depth must be positive");
    return 0;
  }
  const gp_Ax3 f = toAx3(at);
  const gp_Pnt o = f.Location();
  const gp_Vec x(f.XDirection()), z(f.Direction());
  auto pt = [&](double rr, double zz) { return o.Translated(x * rr + z * zz); };
  const double top = std::max(1e-3, 1e-3 * depth);  // start just above the face so the cut is clean

  // The half-profile in (radius, height), from the axis at the top round to the axis at the bottom.
  std::vector<std::pair<gp_Pnt, std::string>> pts;  // point, name of the face the edge from it makes
  const double R = headDiameter / 2;
  switch (kind) {
    case SK_HOLE_COUNTERBORE:
      if (R <= r || headDepth <= 0 || headDepth >= depth) {
        setError("the counterbore must be wider than the hole and shallower than it");
        return 0;
      }
      pts = {{pt(0, top), "top"}, {pt(R, top), "head"}, {pt(R, -headDepth), "floor"}, {pt(r, -headDepth), "wall"}};
      break;
    case SK_HOLE_COUNTERSINK: {
      if (R <= r || headAngle <= 0 || headAngle >= M_PI) {
        setError("the countersink must be wider than the hole, with an angle between 0 and 180 deg");
        return 0;
      }
      const double sinkDepth = (R - r) / std::tan(headAngle / 2);
      if (sinkDepth >= depth) {
        setError("the countersink is deeper than the hole");
        return 0;
      }
      pts = {{pt(0, top), "top"}, {pt(R + top * std::tan(headAngle / 2), top), "head"}, {pt(r, -sinkDepth), "wall"}};
      break;
    }
    default:
      pts = {{pt(0, top), "top"}, {pt(r, top), "wall"}};
  }
  pts.push_back({pt(r, -depth), "tip"});
  const double tip = tipAngle > 0 && tipAngle < M_PI ? r / std::tan(tipAngle / 2) : 0;
  pts.push_back({pt(0, -depth - tip), "axis"});

  BRepBuilderAPI_MakePolygon poly;
  for (auto &p : pts) poly.Add(p.first);
  poly.Close();
  if (!poly.IsDone()) {
    setError("could not build the hole's profile");
    return 0;
  }
  TopoDS_Face face = BRepBuilderAPI_MakeFace(poly.Wire(), true).Face();
  BRepPrimAPI_MakeRevol rev(face, gp_Ax1(o, f.Direction()));
  rev.Build();
  if (!rev.IsDone()) {
    setError("could not build the hole");
    return 0;
  }
  std::vector<Named> names;
  size_t k = 0;
  for (BRepTools_WireExplorer ex(poly.Wire()); ex.More(); ex.Next(), ++k) {
    if (k >= pts.size() || pts[k].second == "axis") continue;
    for (const TopoDS_Shape &g : rev.Generated(ex.Current()))
      if (g.ShapeType() == TopAbs_FACE) names.push_back({g, feat + "." + (pts[k].second == "tip" && tip == 0 ? "bottom" : pts[k].second)});
  }
  return storeChecked(rev.Shape(), names, feat, "the hole is invalid");
  SK_CATCH(0)
}

SKHandle sk_primitive(SKPrimitive kind, SKFrame frame, double a, double b, double c, double d, const char *featureId) {
  SK_TRY
  const std::string feat = featureOrDefault(featureId, "primitive");
  const gp_Ax3 f = toAx3(frame);
  const gp_Pnt o = f.Location();
  const gp_Ax2 ax(o, f.Direction(), f.XDirection());
  auto positive = [](std::initializer_list<double> v) {
    for (double x : v)
      if (!(x > Precision::Confusion())) return false;
    return true;
  };
  TopoDS_Shape shape;
  std::vector<Named> names;
  switch (kind) {
    case SK_BOX: {
      if (!positive({a, b, c})) { setError("the box sizes must be positive"); return 0; }
      gp_Pnt corner = o.Translated(gp_Vec(f.XDirection()) * (-a / 2) + gp_Vec(f.YDirection()) * (-b / 2));
      shape = BRepPrimAPI_MakeBox(gp_Ax2(corner, f.Direction(), f.XDirection()), a, b, c).Shape();
      break;
    }
    case SK_CYLINDER:
      if (!positive({a, c})) { setError("the cylinder's diameter and height must be positive"); return 0; }
      shape = BRepPrimAPI_MakeCylinder(ax, a / 2, c).Shape();
      break;
    case SK_SPHERE:
      if (!positive({a})) { setError("the sphere's diameter must be positive"); return 0; }
      shape = BRepPrimAPI_MakeSphere(ax, a / 2).Shape();
      break;
    case SK_TORUS:
      if (!positive({a, b}) || b >= a) { setError("the torus needs a tube thinner than its diameter"); return 0; }
      shape = BRepPrimAPI_MakeTorus(ax, a / 2, b / 2).Shape();
      break;
    case SK_COIL: {
      if (!positive({a, b, c, d}) || b >= a) { setError("the coil needs a positive size, and a section thinner than its diameter"); return 0; }
      if (b >= c) { setError("the pitch must be larger than the section, or the turns would overlap"); return 0; }
      Handle(Geom_CylindricalSurface) cyl = new Geom_CylindricalSurface(gp_Ax3(ax), a / 2);
      gp_Lin2d line(gp_Pnt2d(0, 0), gp_Dir2d(2 * M_PI, c));
      const double length = d * std::hypot(2 * M_PI, c);
      TopoDS_Edge helix = BRepBuilderAPI_MakeEdge(new Geom2d_Line(line), cyl, 0, length).Edge();
      BRepLib::BuildCurves3d(helix);
      TopoDS_Wire spine = BRepBuilderAPI_MakeWire(helix).Wire();
      if (!sweepCircle(spine, b / 2, true, feat, "side", shape, names)) return 0;
      break;
    }
  }
  nameByDirection(shape, f, feat, names);
  return storeChecked(shape, names, feat, "the primitive is invalid");
  SK_CATCH(0)
}

bool sk_body_face_cylinder(SKHandle body, const char *faceName, bool flipped, double out[9]) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return false;
  auto it = b->faceIndex.find(faceName);
  if (it == b->faceIndex.end()) {
    setError(std::string("face not found: ") + faceName);
    return false;
  }
  Cylinder c;
  if (!cylinderOf(*b, TopoDS::Face(b->faces(it->second + 1)), flipped, c)) return false;
  const double v[9] = {c.start.X(), c.start.Y(), c.start.Z(), c.dir.X(), c.dir.Y(), c.dir.Z(),
                       c.radius, c.length, c.internal ? 1.0 : 0.0};
  std::copy(v, v + 9, out);
  return true;
  SK_CATCH(false)
}

SKHandle sk_thread(SKHandle body, const char *faceName, double majorDiameter, double pitch, double length, bool flipped,
                   bool leftHanded, const char *featureId) {
  SK_TRY
  const std::string feat = featureOrDefault(featureId, "thread");
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return 0;
  auto it = b->faceIndex.find(faceName);
  if (it == b->faceIndex.end()) {
    setError(std::string("face not found: ") + faceName);
    return 0;
  }
  Cylinder c;
  if (!cylinderOf(*b, TopoDS::Face(b->faces(it->second + 1)), flipped, c)) return 0;
  const double P = pitch, rMajor = majorDiameter / 2;
  const double rMinor = rMajor - 0.541265877365 * P;  // basic profile: 5/8 of the 60° triangle deep
  if (!(P > Precision::Confusion()) || !(rMinor > Precision::Confusion())) {
    setError("the thread's diameter and pitch must be positive, and the pitch small enough for the diameter");
    return 0;
  }
  // The thread must suit the face: a bolt thread about as wide as the shaft, a nut thread about
  // as wide as the hole (between its tap drill and its full size).
  const double R = c.radius;
  const bool fits = c.internal ? (R > rMinor * 0.8 && R < rMajor * 1.1) : (R > rMajor * 0.8 && R < rMajor * 1.25);
  if (!fits) {
    char msg[200];
    std::snprintf(msg, sizeof msg, "a %.4g mm thread doesn't fit a %.4g mm %s; pick a size near it", majorDiameter, 2 * R,
                  c.internal ? "hole" : "shaft");
    setError(msg);
    return 0;
  }
  const bool full = length <= 0 || length >= c.length - 1e-6;
  const double L = full ? c.length : length;
  if (length > c.length + 1e-6) {
    char msg[120];
    std::snprintf(msg, sizeof msg, "the thread is longer than the round face (%.4g mm)", c.length);
    setError(msg);
    return 0;
  }
  if (L < P) {
    setError("the thread must be at least one pitch long");
    return 0;
  }
  const gp_Ax3 f(c.start, c.dir, c.radial);
  // Past an open end the thread runs out into the air; at a shoulder or a hole's floor it stops flat.
  const double z0 = c.freeStart ? -P : 0, z1 = full && c.freeEnd ? L + P : L;
  const double tol = 1e-4;
  TopoDS_Shape shape = b->shape;
  std::vector<Named> names = namedFaces(*b);
  const std::string crest = feat + ".thread.crest";
  bool ok = true;
  // The groove between the teeth (ISO 68 basic profile: flats of P/8 at the major diameter and P/4 at
  // the minor, 30° flanks), reaching past the crests so the cut is clean. The flanks run on a little
  // past the crest diameter before the groove turns square: a groove edge lying exactly on the
  // crest cylinder (where the rings below have their faces) makes OCCT's booleans quietly fail.
  const double t30 = std::tan(M_PI / 6);
  std::vector<std::pair<double, double>> groove;
  if (c.internal) {
    auto z = [&](double r) { return P / 16 + (rMajor - r) * t30; };  // half-width at radius r
    const double r1 = rMinor - P / 20, r2 = rMinor - P / 4;
    groove = {{r2, -z(r1)}, {r1, -z(r1)}, {rMajor, -z(rMajor)}, {rMajor, z(rMajor)}, {r1, z(r1)}, {r2, z(r1)}};
  } else {
    auto z = [&](double r) { return P / 8 + (r - rMinor) * t30; };
    const double r1 = rMajor + P / 20, r2 = rMajor + P / 4;
    groove = {{rMinor, -z(rMinor)}, {r1, -z(r1)}, {r2, -z(r1)}, {r2, z(r1)}, {r1, z(r1)}, {rMinor, z(rMinor)}};
  }
  TopoDS_Shape sweep;
  std::vector<Named> none;
  if (!helicalSweep(f, P, z0 - P, z1 + P, leftHanded, groove, sweep) ||
      !namedBoolean(sweep, none, ring(f, 0, rMajor + P, z0, z1), "", SK_COMMON)) {
    setError("could not build the thread's helix");
    return 0;
  }
  auto volume = [](const TopoDS_Shape &sh) {
    GProp_GProps g;
    BRepGProp::VolumeProperties(sh, g);
    return g.Mass();
  };
  // No face of the groove may lie on a face of the body (the original round face is often exactly at
  // a crest or root diameter): OCCT's booleans can then quietly return the body unchanged, or empty.
  TopoDS_Shape fill;
  if (c.internal) {
    // Bore the hole out past the major diameter, then put the whole thread zone back as a ring from
    // the minor diameter out into the wall, with the groove taken out of it. The groove only ever
    // meets that ring, whose faces are well clear of it.
    const double rBore = std::max(R, rMajor) + P / 4;
    ok = namedBoolean(shape, names, ring(f, 0, rBore, z0, z1), crest, SK_CUT);
    fill = ring(f, rMinor, rBore + P / 4, 0, L);
  } else {
    // Turn a thicker shaft down to the major diameter and cut the groove; fill a thinner one out to it.
    if (R > rMajor + tol) ok = namedBoolean(shape, names, ring(f, rMajor, R + P, z0, z1), crest, SK_CUT);
    const double before = volume(shape);
    ok = ok && namedBoolean(shape, names, sweep, feat + ".thread", SK_CUT) && volume(shape) < before - 1e-9;
    if (R < rMajor - tol) fill = ring(f, R * 0.5, rMajor, 0, L);
  }
  if (!ok) {
    setError("could not cut the thread");
    return 0;
  }
  if (!fill.IsNull()) {
    std::vector<Named> fillNames;
    for (TopExp_Explorer ex(fill, TopAbs_FACE); ex.More(); ex.Next()) fillNames.push_back({ex.Current(), crest});
    if (!namedBoolean(fill, fillNames, sweep, feat + ".thread", SK_CUT) || volume(fill) < 1e-9) {
      setError("could not cut the thread");
      return 0;
    }
    std::vector<Named> merged;
    BRepAlgoAPI_Fuse fuse(shape, fill);
    fuse.SetRunParallel(true);
    fuse.Build();
    if (!fuse.IsDone() || fuse.HasErrors() || volume(fuse.Shape()) < volume(shape) + 1e-9) {
      setError("could not cut the thread");
      return 0;
    }
    carry(fuse, names, merged);
    carry(fuse, fillNames, merged);
    shape = fuse.Shape();
    names = std::move(merged);
  }
  TopoDS_Shape result = unify(shape, names);
  return storeChecked(result, names, feat + ".thread", "the thread produced an invalid solid");
  SK_CATCH(0)
}

static SKHandle transformed(SKHandle body, const gp_Trsf &t, const char *prefix = nullptr) {
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return 0;
  BRepBuilderAPI_Transform tr(b->shape, t, true);
  if (!tr.IsDone()) {
    setError("could not move the body");
    return 0;
  }
  const std::string pre = prefix ? prefix : "";
  std::vector<Named> names;
  for (const Named &n : namedFaces(*b)) names.push_back({tr.ModifiedShape(n.shape), pre + n.name});
  return store(makeBody(tr.Shape(), names, pre + "moved"));
}

SKHandle sk_translate_copy(SKHandle body, double dx, double dy, double dz, const char *prefix) {
  SK_TRY
  gp_Trsf t;
  t.SetTranslation(gp_Vec(dx, dy, dz));
  return transformed(body, t, prefix);
  SK_CATCH(0)
}

SKHandle sk_rotate_copy(SKHandle body, double ox, double oy, double oz, double ax, double ay, double az, double angle,
                        const char *prefix) {
  SK_TRY
  gp_Trsf t;
  t.SetRotation(gp_Ax1(gp_Pnt(ox, oy, oz), gp_Dir(ax, ay, az)), angle);
  return transformed(body, t, prefix);
  SK_CATCH(0)
}

SKHandle sk_mirror_copy(SKHandle body, double ox, double oy, double oz, double nx, double ny, double nz, const char *prefix) {
  SK_TRY
  gp_Trsf t;
  t.SetMirror(gp_Ax2(gp_Pnt(ox, oy, oz), gp_Dir(nx, ny, nz)));
  return transformed(body, t, prefix);
  SK_CATCH(0)
}

SKHandle sk_shell(SKHandle body, const char *const *faceNames, int count, double thickness, bool inside, const char *featureId) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return 0;
  if (thickness <= Precision::Confusion()) {
    setError("the wall thickness must be positive");
    return 0;
  }
  ShapeList removed;
  for (int k = 0; k < count; ++k) {
    auto it = b->faceIndex.find(faceNames[k]);
    if (it == b->faceIndex.end()) {
      setError(std::string("face not found: ") + faceNames[k]);
      return 0;
    }
    removed.Append(b->faces(it->second + 1));
  }
  BRepOffsetAPI_MakeThickSolid mk;
  mk.MakeThickSolidByJoin(b->shape, removed, inside ? -thickness : thickness, 1e-3);
  mk.Build();
  if (!mk.IsDone()) {
    setError("shell failed (is the wall thicker than the body allows?)");
    return 0;
  }
  const std::string feat = featureOrDefault(featureId, "shell");
  std::vector<Named> names;
  carry(mk, namedFaces(*b), names);
  Body out = makeBody(mk.Shape(), names, feat + ".shell");
  if (!BRepCheck_Analyzer(out.shape).IsValid()) {
    setError("shell failed (is the wall thicker than the body allows?)");
    return 0;
  }
  return store(std::move(out));
  SK_CATCH(0)
}

bool sk_body_edge_line(SKHandle body, const char *edgeName, double out[6]) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return false;
  auto it = b->edgeIndex.find(edgeName);
  if (it == b->edgeIndex.end()) {
    setError(std::string("edge not found: ") + edgeName);
    return false;
  }
  BRepAdaptor_Curve c(TopoDS::Edge(b->edges(it->second + 1)));
  if (c.GetType() != GeomAbs_Line) {
    setError("that edge isn't straight");
    return false;
  }
  gp_Lin line = c.Line();
  gp_Pnt p = c.Value(c.FirstParameter());
  out[0] = p.X(); out[1] = p.Y(); out[2] = p.Z();
  out[3] = line.Direction().X(); out[4] = line.Direction().Y(); out[5] = line.Direction().Z();
  return true;
  SK_CATCH(false)
}

bool sk_body_edge_ends(SKHandle body, const char *edgeName, double out[6]) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return false;
  auto it = b->edgeIndex.find(edgeName);
  if (it == b->edgeIndex.end()) {
    setError(std::string("edge not found: ") + edgeName);
    return false;
  }
  BRepAdaptor_Curve c(TopoDS::Edge(b->edges(it->second + 1)));
  if (c.GetType() != GeomAbs_Line) {
    setError("that edge isn't straight");
    return false;
  }
  gp_Pnt p = c.Value(c.FirstParameter()), q = c.Value(c.LastParameter());
  out[0] = p.X(); out[1] = p.Y(); out[2] = p.Z();
  out[3] = q.X(); out[4] = q.Y(); out[5] = q.Z();
  return true;
  SK_CATCH(false)
}

SKHandle sk_translate(SKHandle body, double dx, double dy, double dz) {
  SK_TRY
  gp_Trsf t;
  t.SetTranslation(gp_Vec(dx, dy, dz));
  return transformed(body, t);
  SK_CATCH(0)
}

SKHandle sk_rotate(SKHandle body, double ox, double oy, double oz, double ax, double ay, double az, double angle) {
  SK_TRY
  gp_Trsf t;
  t.SetRotation(gp_Ax1(gp_Pnt(ox, oy, oz), gp_Dir(ax, ay, az)), angle);
  return transformed(body, t);
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
    case SK_FUSE: bop = std::make_unique<BRepAlgoAPI_Fuse>(); break;
    case SK_CUT: bop = std::make_unique<BRepAlgoAPI_Cut>(); break;
    case SK_COMMON: bop = std::make_unique<BRepAlgoAPI_Common>(); break;
  }
  ShapeList args, tools;
  args.Append(a->shape);
  tools.Append(b->shape);
  bop->SetArguments(args);
  bop->SetTools(tools);
  bop->SetRunParallel(true);  // many faces (text, patterns) intersect faster on all cores
  bop->Build();
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

int sk_body_face_edges(SKHandle body, const char *faceName, int *out, int max) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return -1;
  auto it = b->faceIndex.find(faceName);
  if (it == b->faceIndex.end()) {
    setError(std::string("face not found: ") + faceName);
    return -1;
  }
  std::vector<int> found;
  for (TopExp_Explorer ex(b->faces(it->second + 1), TopAbs_EDGE); ex.More(); ex.Next()) {
    int i = b->edges.FindIndex(ex.Current()) - 1;
    if (i < 0 || b->edgeHidden[i] || std::find(found.begin(), found.end(), i) != found.end()) continue;
    found.push_back(i);
  }
  for (int k = 0; k < (int)found.size() && k < max; ++k) out[k] = found[k];
  return (int)found.size();
  SK_CATCH(-1)
}

int sk_body_edge_faces(SKHandle body, const char *edgeName, int *out, int max) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return -1;
  auto it = b->edgeIndex.find(edgeName);
  if (it == b->edgeIndex.end()) {
    setError(std::string("edge not found: ") + edgeName);
    return -1;
  }
  const TopoDS_Shape &edge = b->edges(it->second + 1);
  std::vector<int> found;
  for (int f = 1; f <= b->faces.Extent(); ++f)
    for (TopExp_Explorer ex(b->faces(f), TopAbs_EDGE); ex.More(); ex.Next())
      if (ex.Current().IsSame(edge)) {
        if (std::find(found.begin(), found.end(), f - 1) == found.end()) found.push_back(f - 1);
        break;
      }
  for (int k = 0; k < (int)found.size() && k < max; ++k) out[k] = found[k];
  return (int)found.size();
  SK_CATCH(-1)
}

int sk_body_loop_edges(SKHandle body, const char *faceName, const char *edgeName, int *out, int max) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return -1;
  auto fi = b->faceIndex.find(faceName);
  auto ei = b->edgeIndex.find(edgeName);
  if (fi == b->faceIndex.end() || ei == b->edgeIndex.end()) {
    setError("face or edge not found");
    return -1;
  }
  const TopoDS_Shape &edge = b->edges(ei->second + 1);
  std::vector<int> found;
  for (TopExp_Explorer wires(b->faces(fi->second + 1), TopAbs_WIRE); wires.More(); wires.Next()) {
    bool mine = false;
    for (TopExp_Explorer ex(wires.Current(), TopAbs_EDGE); ex.More() && !mine; ex.Next()) mine = ex.Current().IsSame(edge);
    if (!mine) continue;
    for (TopExp_Explorer ex(wires.Current(), TopAbs_EDGE); ex.More(); ex.Next()) {
      int i = b->edges.FindIndex(ex.Current()) - 1;
      if (i < 0 || b->edgeHidden[i] || std::find(found.begin(), found.end(), i) != found.end()) continue;
      found.push_back(i);
    }
    break;
  }
  for (int k = 0; k < (int)found.size() && k < max; ++k) out[k] = found[k];
  return (int)found.size();
  SK_CATCH(-1)
}

SKHandle sk_body_face_profile(SKHandle body, const char *faceName) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return 0;
  auto it = b->faceIndex.find(faceName);
  if (it == b->faceIndex.end()) {
    setError(std::string("face not found: ") + faceName);
    return 0;
  }
  const TopoDS_Face &f = TopoDS::Face(b->faces(it->second + 1));
  if (BRepAdaptor_Surface(f).GetType() != GeomAbs_Plane) {
    setError(std::string("only flat faces can be extruded: ") + faceName);
    return 0;
  }
  // A copy, so the profile doesn't share (and later mesh) the body's topology.
  BRepBuilderAPI_Copy copy(f);
  Profile p;
  p.face = TopoDS::Face(copy.Shape());
  for (TopExp_Explorer ex(f, TopAbs_EDGE); ex.More(); ex.Next()) {
    int e = b->edges.FindIndex(ex.Current());
    if (e > 0) p.edgeTags.push_back({copy.ModifiedShape(ex.Current()), b->edgeNames[e - 1]});
  }
  if (p.face.Orientation() == TopAbs_REVERSED) p.face.Reverse();
  return store(std::move(p));
  SK_CATCH(0)
}

bool sk_body_face_center(SKHandle body, const char *faceName, double out[3]) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return false;
  auto it = b->faceIndex.find(faceName);
  if (it == b->faceIndex.end()) {
    setError(std::string("face not found: ") + faceName);
    return false;
  }
  GProp_GProps props;
  BRepGProp::SurfaceProperties(b->faces(it->second + 1), props);
  gp_Pnt c = props.CentreOfMass();
  out[0] = c.X(); out[1] = c.Y(); out[2] = c.Z();
  return true;
  SK_CATCH(false)
}

bool sk_body_face_outline_center(SKHandle body, const char *faceName, double out[3]) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return false;
  auto it = b->faceIndex.find(faceName);
  if (it == b->faceIndex.end()) {
    setError(std::string("face not found: ") + faceName);
    return false;
  }
  // The centre of the area inside the face's outer boundary: holes in the face don't pull it aside.
  const TopoDS_Face &f = TopoDS::Face(b->faces(it->second + 1));
  TopoDS_Wire outer = BRepTools::OuterWire(f);
  GProp_GProps props;
  if (!outer.IsNull()) {
    BRepBuilderAPI_MakeFace filled(BRep_Tool::Surface(f), outer, Standard_True);
    if (filled.IsDone()) BRepGProp::SurfaceProperties(filled.Face(), props);
  }
  if (std::abs(props.Mass()) < 1e-12) BRepGProp::SurfaceProperties(f, props);  // no usable outline: the face itself
  gp_Pnt c = props.CentreOfMass();
  out[0] = c.X(); out[1] = c.Y(); out[2] = c.Z();
  return true;
  SK_CATCH(false)
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

bool sk_body_edge_handle(SKHandle body, const char *edgeName, double out[6]) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return false;
  auto it = b->edgeIndex.find(edgeName);
  if (it == b->edgeIndex.end()) {
    setError(std::string("edge not found: ") + edgeName);
    return false;
  }
  const TopoDS_Edge &e = TopoDS::Edge(b->edges(it->second + 1));
  ShapeToShapes edgeFaces;
  TopExp::MapShapesAndUniqueAncestors(b->shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
  if (!edgeFaces.Contains(e) || edgeFaces.FindFromKey(e).Extent() != 2) {
    setError("the edge must join two faces");
    return false;
  }
  BRepAdaptor_Curve curve(e);
  const double t = 0.5 * (curve.FirstParameter() + curve.LastParameter());
  const gp_Pnt mid = curve.Value(t);

  // Outward normals of the two faces at the edge midpoint.
  std::vector<gp_Vec> normals;
  for (const TopoDS_Shape &fs : edgeFaces.FindFromKey(e)) {
    const TopoDS_Face &f = TopoDS::Face(fs);
    BRepAdaptor_Surface surf(f);
    double f0, l0;
    Handle(Geom2d_Curve) pc = BRep_Tool::CurveOnSurface(e, f, f0, l0);
    gp_Pnt2d uv;
    if (!pc.IsNull()) {
      uv = pc->Value(t);
    } else {
      GeomAPI_ProjectPointOnSurf proj(mid, BRep_Tool::Surface(f));
      if (proj.NbPoints() == 0) continue;
      double u, v;
      proj.LowerDistanceParameters(u, v);
      uv = gp_Pnt2d(u, v);
    }
    gp_Pnt p;
    gp_Vec du, dv;
    surf.D1(uv.X(), uv.Y(), p, du, dv);
    gp_Vec n = du.Crossed(dv);
    if (n.Magnitude() < 1e-12) continue;
    n.Normalize();
    if (f.Orientation() == TopAbs_REVERSED) n.Reverse();
    normals.push_back(n);
  }
  if (normals.size() != 2) {
    setError("could not evaluate the faces at this edge");
    return false;
  }
  gp_Vec sum = normals[0] + normals[1], diff = normals[0] - normals[1];
  if (sum.Magnitude() < 1e-9 || diff.Magnitude() < 1e-9) {
    setError("the faces at this edge are tangent or opposite");
    return false;
  }
  // Seen along the edge, a point off the corner along (n1 - n2) is outside the material at an
  // outside (convex) corner and inside it at an inside (concave) corner.
  Bnd_Box box;
  BRepBndLib::Add(b->shape, box);
  const double eps = std::max(1e-4, 1e-4 * std::sqrt(box.SquareExtent()));
  BRepClass3d_SolidClassifier probe(b->shape, mid.Translated(diff.Normalized() * eps), 1e-7);
  const bool concave = probe.State() == TopAbs_IN;
  gp_Vec dir = sum.Normalized() * (concave ? 1.0 : -1.0);
  out[0] = mid.X(); out[1] = mid.Y(); out[2] = mid.Z();
  out[3] = dir.X(); out[4] = dir.Y(); out[5] = dir.Z();
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

// ------------------------------------------------------------------ import ---

/// OCCT's data-exchange code prints statistics to stdout; this turns that off once.
static void quietDataExchange() {
  static const bool quiet = [] {
    Message::DefaultMessenger()->RemovePrinters(STANDARD_TYPE(Message_PrinterOStream));
    return true;
  }();
  (void)quiet;
}

SKHandle sk_import_step(const char *data, size_t size, const char *featureId) {
  SK_TRY
  const std::string feat = featureOrDefault(featureId, "import");
  if (!data || size == 0) {
    setError("the STEP file is empty");
    return 0;
  }
  quietDataExchange();
  std::istringstream in(std::string(data, size));
  STEPControl_Reader reader;
  if (reader.ReadStream("import.step", in) != IFSelect_RetDone) {
    setError("this isn't a STEP file SimplCAD can read");
    return 0;
  }
  reader.SetSystemLengthUnit(1.0);  // millimetres, whatever unit the file uses
  if (reader.TransferRoots() == 0) {
    setError("the STEP file has no shapes in it");
    return 0;
  }
  const TopoDS_Shape all = reader.OneShape();

  std::vector<TopoDS_Shape> solids;
  for (TopExp_Explorer ex(all, TopAbs_SOLID); ex.More(); ex.Next()) solids.push_back(ex.Current());
  if (solids.empty()) {
    // A surface model: sew its faces, and make a solid of every shell that closes up.
    BRepBuilderAPI_Sewing sew(1e-3);
    for (TopExp_Explorer ex(all, TopAbs_FACE); ex.More(); ex.Next()) sew.Add(ex.Current());
    sew.Perform();
    for (TopExp_Explorer ex(sew.SewedShape(), TopAbs_SHELL); ex.More(); ex.Next()) {
      const TopoDS_Shell &shell = TopoDS::Shell(ex.Current());
      if (!BRep_Tool::IsClosed(shell)) continue;
      BRepBuilderAPI_MakeSolid mk(shell);
      if (!mk.IsDone()) continue;
      TopoDS_Solid solid = mk.Solid();
      BRepLib::OrientClosedSolid(solid);
      solids.push_back(solid);
    }
  }
  if (solids.empty()) {
    setError("the STEP file has no solids (only open surfaces, curves or points)");
    return 0;
  }

  TopoDS_Shape shape = solids[0];
  if (solids.size() > 1) {
    TopoDS_Compound comp;
    BRep_Builder bb;
    bb.MakeCompound(comp);
    for (const TopoDS_Shape &s : solids) bb.Add(comp, s);
    shape = comp;
  }
  if (!BRepCheck_Analyzer(shape).IsValid()) {  // try to repair it; if that fails, keep it as it is
    ShapeFix_Shape fix(shape);
    fix.Perform();
    if (BRepCheck_Analyzer(fix.Shape()).IsValid()) shape = fix.Shape();
  }

  // A file has no feature history: faces are named by their place in it, which a rebuild repeats.
  std::vector<Named> names;
  ShapeIndexedMap faces;
  TopExp::MapShapes(shape, TopAbs_FACE, faces);
  for (int i = 1; i <= faces.Extent(); ++i) names.push_back({faces(i), feat + ".face" + std::to_string(i)});
  return store(makeBody(shape, names, feat));
  SK_CATCH(0)
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
  quietDataExchange();
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
