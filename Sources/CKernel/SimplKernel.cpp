// SimplKernel — OpenCASCADE implementation of the C API in include/SimplKernel.h.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later

#include "SimplKernel.h"
#include "MeshSimplify.hpp"

#include <algorithm>
#include <atomic>
#include <array>
#include <map>
#include <typeinfo>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <csetjmp>
#include <csignal>
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
#include <BRepAdaptor_CompCurve.hxx>
#include <functional>
#include <GCPnts_AbscissaPoint.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepAlgoAPI_Section.hxx>
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
#include <BRepOffsetAPI_MakeOffsetShape.hxx>
#include <BRepOffset_MakeOffset.hxx>
#include <BRepLProp_SLProps.hxx>
#include <Geom_Surface.hxx>
#include <BRepClass_FaceClassifier.hxx>
#include <BRepBuilderAPI_Copy.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepClass3d_SolidClassifier.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepGProp.hxx>
#include <BRepGProp_Domain.hxx>
#include <BRepGProp_Face.hxx>
#include <BRepGProp_Vinert.hxx>
#include <BRepLib_ToolTriangulatedShape.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepOffsetAPI_DraftAngle.hxx>
#include <BRepTools.hxx>
#include <BRepTools_History.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <Geom_Curve.hxx>
#include <Geom_BSplineCurve.hxx>
#include <Geom_TrimmedCurve.hxx>
#include <Geom_SurfaceOfLinearExtrusion.hxx>
#include <GeomAPI_PointsToBSpline.hxx>
#include <BRepTools_WireExplorer.hxx>
#include <ElSLib.hxx>
#include <GCE2d_MakeSegment.hxx>
#include <Geom2dAPI_Interpolate.hxx>
#include <Geom2d_BSplineCurve.hxx>
#include <Geom2d_TrimmedCurve.hxx>
#include <NCollection_HArray1.hxx>
#include <gp_Pnt2d.hxx>
#include <GeomConvert.hxx>
#include <GeomConvert_CompCurveToBSplineCurve.hxx>
#include <ShapeFix_Face.hxx>
#include <ShapeFix_FixSmallFace.hxx>
#include <ShapeBuild_ReShape.hxx>
#include <TopLoc_Location.hxx>
#include <Bnd_Box.hxx>
#include <Geom2d_Curve.hxx>
#include <GeomAPI_ProjectPointOnSurf.hxx>
#include <IntCurvesFace_ShapeIntersector.hxx>
#include <GCPnts_TangentialDeflection.hxx>
#include <GProp_GProps.hxx>
#include <GeomAbs_SurfaceType.hxx>
#include <Message.hxx>
#include <Message_Messenger.hxx>
#include <Message_PrinterOStream.hxx>
#include <OSD_Parallel.hxx>
#include <Poly_Triangulation.hxx>
#include <RWStl.hxx>
#include <STEPControl_Reader.hxx>
#include <STEPControl_Writer.hxx>
#include <ShapeBuild_ReShape.hxx>
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
#include <TopoDS_Iterator.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shell.hxx>
#include <TopoDS_Solid.hxx>
#include <NCollection_Map.hxx>
#include <gp_Ax1.hxx>
#include <gp_Ax2.hxx>
#include <gp_Ax3.hxx>
#include <gp_Circ.hxx>
#include <gp_Cone.hxx>
#include <gp_Cylinder.hxx>
#include <gp_Pln.hxx>
#include <gp_Sphere.hxx>
#include <gp_Torus.hxx>
#include <gp_Trsf.hxx>
#include <gp_Vec.hxx>

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

// OpenCASCADE's round and chamfer builders can fault outright on some geometry (a null curve deep in the blend, found
// on a body with a swept cove: the whole app went down with it), and a fault is no C++ exception, so nothing in
// SK_CATCH sees it. Its own conversion to an exception needs OCCT built with OCC_CONVERT_SIGNALS, which ours is not.
// So the builders run under runGuarded: a SIGSEGV or SIGBUS on this thread while a guard is up jumps back to it, and
// the call fails like any other round that cannot be built. The builder is left as it fell (the caller must not
// destroy it), and a fault with no guard up goes on to whatever handler was there before.
thread_local sigjmp_buf *g_faultJump = nullptr;
struct sigaction g_previousSegv, g_previousBus;

void faultHandler(int sig, siginfo_t *, void *) {
  if (g_faultJump) siglongjmp(*g_faultJump, 1);
  sigaction(sig, sig == SIGSEGV ? &g_previousSegv : &g_previousBus, nullptr);  // not ours: fault again into the old handler
}

void installFaultHandler() {
  static std::once_flag once;
  std::call_once(once, [] {
    struct sigaction action;
    sigemptyset(&action.sa_mask);
    action.sa_sigaction = faultHandler;
    action.sa_flags = SA_SIGINFO | SA_NODEFER;
    sigaction(SIGSEGV, &action, &g_previousSegv);
    sigaction(SIGBUS, &action, &g_previousBus);
  });
}

/// Runs `body`; false when it faulted instead (nothing it built can be trusted, nor anything it was holding).
template <class F>
bool runGuarded(F &&body) {
  installFaultHandler();
  sigjmp_buf jump;
  sigjmp_buf *outer = g_faultJump;
  if (sigsetjmp(jump, 1) == 0) {
    g_faultJump = &jump;
    body();
    g_faultJump = outer;
    return true;
  }
  g_faultJump = outer;
  return false;
}

#define SK_TRY try {
#define SK_CATCH(ret)                                          \
  }                                                            \
  catch (const Standard_Failure &e) {                          \
    /* Some OpenCASCADE failures carry no message: name the kind of failure instead. */ \
    std::string what = e.what() ? e.what() : "";               \
    if (what.empty()) {                                        \
      what = typeid(e).name();                                 \
      while (!what.empty() && isdigit((unsigned char)what[0])) what.erase(0, 1); \
    }                                                          \
    setError(std::string("kernel: ") + what);                  \
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

/// The smallest radius of a rounded corner that a chamfer along `edges` would shrink: an arc or circle in the
/// edges' tangent chains whose flat face lies inside it (a plate's rounded corner, the top of a boss). Chamfering
/// the corner by that much or more folds the cone through its own axis, so the result is no solid. (A fillet that
/// size builds a valid solid, so fillets aren't held to it.)
/// Holes don't count: their flat face is outside the circle, so chamfering only widens them. False if there is none.
template <class Maker>
bool cornerRadiusLimitIn(Body &b, Maker &mk, double &radius) {
  try {
    ShapeToShapes edgeFaces;
    bool mapped = false;  // only a body with a round edge in the chains pays for the map
    bool found = false;
    for (int ic = 1; ic <= mk.NbContours(); ++ic)
      for (int j = 1; j <= mk.NbEdges(ic); ++j) {
        const TopoDS_Edge &e = mk.Edge(ic, j);
        BRepAdaptor_Curve c(e);
        if (c.GetType() != GeomAbs_Circle) continue;
        if (!mapped) {
          TopExp::MapShapesAndUniqueAncestors(b.shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
          mapped = true;
        }
        if (!edgeFaces.Contains(e)) continue;
        const gp_Circ circ = c.Circle();
        const gp_Pnt at = c.Value(0.5 * (c.FirstParameter() + c.LastParameter()));
        const gp_Vec inward(at, circ.Location());
        if (inward.Magnitude() < Precision::Confusion()) continue;
        const gp_Pnt probe = at.Translated(inward.Normalized() * std::min(0.01, 0.01 * circ.Radius()));
        for (const TopoDS_Shape &fs : edgeFaces.FindFromKey(e)) {
          const TopoDS_Face &f = TopoDS::Face(fs);
          BRepAdaptor_Surface surf(f);
          if (surf.GetType() != GeomAbs_Plane) continue;
          if (std::abs(surf.Plane().Axis().Direction().Dot(circ.Axis().Direction())) < 0.999) continue;
          BRepClass_FaceClassifier inside(f, probe, 1e-7);
          if (inside.State() != TopAbs_IN) continue;
          radius = found ? std::min(radius, circ.Radius()) : circ.Radius();
          found = true;
        }
      }
    return found;
  } catch (Standard_Failure &) {
    return false;
  }
}

bool cornerRadiusLimit(Body &b, const std::vector<TopoDS_Edge> &edges, double &radius) {
  try {
    BRepFilletAPI_MakeChamfer mk(b.shape);
    for (const TopoDS_Edge &e : edges) mk.Add(Precision::Confusion() * 10, e);  // Add finds each edge's tangent chain
    return cornerRadiusLimitIn(b, mk, radius);
  } catch (Standard_Failure &) {
    return false;
  }
}

std::string cornerText(double r, const char *kind) {
  char buf[200];
  std::snprintf(buf, sizeof buf, "the corner it runs round has a radius of %.4g mm, so a %s has to be smaller than that", r, kind);
  return buf;
}

/// How a failed chamfer of `size` along `edges` reads when a rounded corner is the reason (see
/// cornerRadiusLimit); empty if it isn't, or if `size` is 0 (a chamfer measured two ways has no one size to compare).
std::string cornerMessage(Body &b, const std::vector<TopoDS_Edge> &edges, const char *kind, double size) {
  double r;
  if (size <= 0 || !cornerRadiusLimit(b, edges, r) || size < r - 1e-6) return "";
  return cornerText(r, kind);
}

/// The same, from a maker the edges are already added to: adding them again is the longest step of a chamfer on a
/// body with many edges, and the maker has the tangent chains already.
template <class Maker>
std::string cornerMessageIn(Body &b, Maker &mk, const char *kind, double size) {
  double r;
  if (size <= 0 || !cornerRadiusLimitIn(b, mk, r) || size < r - 1e-6) return "";
  return cornerText(r, kind);
}

/// How a failed round or chamfer along `edges` reads when a short edge in their tangent chains is the reason: a size
/// bigger than the shortest edge it runs along doesn't fit, and a hair-thin face (two rounds that use up a whole face
/// between them leave one) is more than OCCT can follow, whatever the size. Empty when there is no such edge (a
/// chamfer measured two ways has no one size, so only the hair-thin face counts then).
std::string sliverMessage(Body &b, const std::vector<TopoDS_Edge> &edges, const char *kind, double size) {
  try {
    BRepFilletAPI_MakeChamfer mk(b.shape);
    for (const TopoDS_Edge &e : edges) mk.Add(Precision::Confusion() * 10, e);  // Add finds each edge's tangent chain
    double shortest = 1e30;
    for (int ic = 1; ic <= mk.NbContours(); ++ic)
      for (int j = 1; j <= mk.NbEdges(ic); ++j) {
        GProp_GProps props;
        BRepGProp::LinearProperties(mk.Edge(ic, j), props);
        shortest = std::min(shortest, props.Mass());
      }
    char buf[280];
    if (shortest < 1e-3) {
      std::snprintf(buf, sizeof buf,
                    "the edge runs past a hair-thin face, which two rounds that use up a whole face between them leave; make one of those rounds a little smaller");
    } else if (size > 0 && shortest < size - 1e-6) {
      std::snprintf(buf, sizeof buf, "a %s of %.4g mm does not fit: the edge has a stretch only %.2g mm long, so make the %s smaller than that",
                    kind, size, shortest, kind);
    } else {
      return "";
    }
    return buf;
  } catch (Standard_Failure &) {
    return "";
  }
}

/// How a failed round or chamfer along `edges` reads when they are part of an outline cut into many short straight
/// pieces (a curve traced with a few dozen lines). OpenCascade takes two walls that meet at less than about 6 degrees
/// for one smooth surface, so such an outline becomes a single chain of near-tangent edges that it cannot follow, at
/// any size; the same outline drawn as a spline or arcs rounds. Empty when no chain of the edges looks like that.
std::string polygonMessage(Body &b, const std::vector<TopoDS_Edge> &edges, const char *kind) {
  try {
    BRepFilletAPI_MakeChamfer mk(b.shape);
    for (const TopoDS_Edge &e : edges) mk.Add(Precision::Confusion() * 10, e);  // Add finds each edge's tangent chain
    for (int ic = 1; ic <= mk.NbContours(); ++ic) {
      const int n = mk.NbEdges(ic);
      if (n < 10) continue;
      std::vector<gp_Vec> along;
      double shortest = 1e30;
      for (int j = 1; j <= n; ++j) {
        const TopoDS_Edge &e = mk.Edge(ic, j);
        if (BRepAdaptor_Curve(e).GetType() != GeomAbs_Line) break;
        const gp_Vec v(BRep_Tool::Pnt(TopExp::FirstVertex(e, true)), BRep_Tool::Pnt(TopExp::LastVertex(e, true)));
        if (v.Magnitude() < 1e-9) break;
        along.push_back(v);
        shortest = std::min(shortest, v.Magnitude());
      }
      if ((int)along.size() < n) continue;  // some piece is curved: this is not a polygon
      double turned = 0;
      for (int j = 0; j + 1 < n; ++j) turned += along[j].Angle(along[j + 1]);
      if (turned < 0.2) continue;  // straight on: nothing the kernel has to follow round a bend
      char buf[330];
      std::snprintf(buf, sizeof buf,
                    "the edge is part of an outline of %d short straight pieces (the shortest %.2g mm) that bend %.0f degrees in all. The kernel cannot follow "
                    "a curve cut into pieces like that, whatever the %s size: draw the outline as a spline or as arcs instead",
                    n, shortest, turned * 180 / M_PI, kind);
      return buf;
    }
    return "";
  } catch (Standard_Failure &) {
    return "";
  }
}

/// Why a round or chamfer failed, when something the body has (a rounded corner, a very short edge) explains it.
std::string failureMessage(Body &b, const std::vector<TopoDS_Edge> &edges, const char *kind, double size) {
  std::string why = cornerMessage(b, edges, kind, size);
  if (why.empty()) why = polygonMessage(b, edges, kind);
  return why.empty() ? sliverMessage(b, edges, kind, size) : why;
}

/// Whether a face of the shape is a straight extrusion of a spline of several spans (what a run of merged curves
/// gives), the one kind of face whose plain volume integral is up to a percent or two off.
bool hasSplineExtrusion(const TopoDS_Shape &shape) {
  for (TopExp_Explorer ex(shape, TopAbs_FACE); ex.More(); ex.Next()) {
    Handle(Geom_SurfaceOfLinearExtrusion) e =
        Handle(Geom_SurfaceOfLinearExtrusion)::DownCast(BRep_Tool::Surface(TopoDS::Face(ex.Current())));
    Handle(Geom_BSplineCurve) b = e.IsNull() ? nullptr : Handle(Geom_BSplineCurve)::DownCast(e->BasisCurve());
    if (!b.IsNull() && b->NbKnots() > 2) return true;
  }
  return false;
}

/// How much more volume `after` encloses than `before`, with only the faces that differ between them integrated:
/// a body's volume is the sum of its faces' shares (the cone from a reference point to each face, which is what
/// BRepGProp adds up), so the faces both have cancel out and need no integral. A round or chamfer changes a few faces
/// of a body that may have hundreds of them, and the integral over the helical faces of a thread is what takes the
/// time. A face is the same in both when it has the same surface, position and orientation. Every share is taken from
/// one point (BRepGProp picks its own for each shape, which would make the two bodies' shares incomparable): the
/// middle of the faces that differ.
double volumeChange(const TopoDS_Shape &before, const TopoDS_Shape &after) {
  auto faces = [](const TopoDS_Shape &shape) {
    NCollection_Map<TopoDS_Shape> set;
    for (TopExp_Explorer ex(shape, TopAbs_FACE); ex.More(); ex.Next()) set.Add(ex.Current());
    return set;
  };
  const NCollection_Map<TopoDS_Shape> was = faces(before), now = faces(after);
  std::vector<TopoDS_Face> added, removed;
  for (const TopoDS_Shape &f : now)
    if (!was.Contains(f)) added.push_back(TopoDS::Face(f));
  for (const TopoDS_Shape &f : was)
    if (!now.Contains(f)) removed.push_back(TopoDS::Face(f));
  Bnd_Box box;
  for (const auto *list : {&added, &removed})
    for (const TopoDS_Face &f : *list) BRepBndLib::Add(f, box);
  if (box.IsVoid()) return 0;
  double x0, y0, z0, x1, y1, z1;
  box.Get(x0, y0, z0, x1, y1, z1);
  const gp_Pnt reference((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2);
  BRepGProp_Vinert integral;
  integral.SetLocation(reference);
  auto share = [&](const TopoDS_Face &f) {
    BRepGProp_Face face;
    BRepGProp_Domain domain;
    face.Load(f);
    if (f.NbChildren() == 0) {
      integral.Perform(face);
    } else {
      domain.Init(f);
      integral.Perform(face, domain);
    }
    return integral.Mass();
  };
  double change = 0;
  for (const TopoDS_Face &f : added) change += share(f);
  for (const TopoDS_Face &f : removed) change -= share(f);
  return change;
}

/// True when every edge of `edges` is a convex edge of `shape`. Rounding only convex edges takes material away, so
/// a rounded body that is bigger than before is wrong; rounding a concave edge fills the corner and does add some.
/// An edge that is concave, tangent or not shared by exactly two faces counts as not convex.
bool allConvex(const TopoDS_Shape &shape, const std::vector<TopoDS_Edge> &edges) {
  try {
    ShapeToShapes edgeFaces;
    TopExp::MapShapesAndUniqueAncestors(shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
    // The outward normal of `f` where `e` meets it, and the direction along `e` the way `f`'s outline runs.
    auto frame = [](const TopoDS_Edge &e, const TopoDS_Face &f, gp_Vec &n, gp_Vec &t) {
      double f0, l0;
      Handle(Geom2d_Curve) pc = BRep_Tool::CurveOnSurface(e, f, f0, l0);
      if (pc.IsNull()) return false;
      const gp_Pnt2d uv = pc->Value(0.5 * (f0 + l0));
      BRepAdaptor_Surface surf(f);
      gp_Pnt p;
      gp_Vec du, dv;
      surf.D1(uv.X(), uv.Y(), p, du, dv);
      n = du.Crossed(dv);
      if (n.Magnitude() < Precision::Confusion()) return false;
      n.Normalize();
      if (f.Orientation() == TopAbs_REVERSED) n.Reverse();
      int seen = 0;
      TopAbs_Orientation o = TopAbs_FORWARD;
      for (TopExp_Explorer ex(f, TopAbs_EDGE); ex.More(); ex.Next())
        if (ex.Current().IsSame(e)) {
          o = ex.Current().Orientation();
          ++seen;
        }
      if (seen != 1) return false;  // a seam runs both ways
      BRepAdaptor_Curve c(e);
      gp_Pnt at;
      c.D1(0.5 * (c.FirstParameter() + c.LastParameter()), at, t);
      if (t.Magnitude() < Precision::Confusion()) return false;
      t.Normalize();
      if (o == TopAbs_REVERSED) t.Reverse();
      return true;
    };
    for (const TopoDS_Edge &e : edges) {
      if (!edgeFaces.Contains(e)) return false;
      const ShapeList &fl = edgeFaces.FindFromKey(e);
      if (fl.Size() != 2) return false;
      std::vector<TopoDS_Face> fs;
      for (const TopoDS_Shape &x : fl) fs.push_back(TopoDS::Face(x));
      gp_Vec n1, t1, n2, t2;
      if (!frame(e, fs[0], n1, t1) || !frame(e, fs[1], n2, t2)) return false;
      // From the edge into face 1 (left of its outline seen from outside) the other face's plane is left behind
      // on a convex edge and crossed to its outside on a concave one.
      const gp_Vec into1 = n1.Crossed(t1);
      if (n2.Dot(into1) > -1e-6) return false;
    }
    return true;
  } catch (Standard_Failure &) {
    return false;
  }
}

/// The length of the shortest edge in the tangent chains of `edges`, 0 if there is none (see sliverMessage).
double shortestChainEdge(Body &b, const std::vector<TopoDS_Edge> &edges) {
  try {
    BRepFilletAPI_MakeChamfer mk(b.shape);
    for (const TopoDS_Edge &e : edges) mk.Add(Precision::Confusion() * 10, e);
    double shortest = 0;
    bool any = false;
    for (int ic = 1; ic <= mk.NbContours(); ++ic)
      for (int j = 1; j <= mk.NbEdges(ic); ++j) {
        GProp_GProps props;
        BRepGProp::LinearProperties(mk.Edge(ic, j), props);
        shortest = any ? std::min(shortest, props.Mass()) : props.Mass();
        any = true;
      }
    return shortest;
  } catch (Standard_Failure &) {
    return 0;
  }
}

/// `b` without its hair-thin strip faces: two rounds that use up a whole face between them leave one (see the nudge in
/// Regenerator.edgeFeature), and a chamfer or round that has to run across it fails whatever its size. The strip goes,
/// the faces on either side meet, and every other face keeps its name. False if nothing was removed or the result is no
/// good (not valid, or a different volume).
bool healStrips(const Body &b, Body &out, const std::string &fallback) {
  try {
    ShapeFix_FixSmallFace fix;
    fix.Init(b.shape);
    fix.SetPrecision(1e-4);
    fix.Perform();
    const TopoDS_Shape healed = fix.FixShape();
    if (healed.IsNull() || !BRepCheck_Analyzer(healed).IsValid()) return false;
    std::vector<Named> names;
    for (const Named &n : namedFaces(b)) {
      const TopoDS_Shape m = fix.Context()->Apply(n.shape);
      if (!m.IsNull() && m.ShapeType() == TopAbs_FACE) names.push_back({m, n.name});
    }
    Body candidate = makeBody(healed, names, fallback);
    if (candidate.faces.Extent() >= b.faces.Extent()) return false;
    GProp_GProps before, after;
    BRepGProp::VolumeProperties(b.shape, before);
    BRepGProp::VolumeProperties(healed, after);
    if (std::abs(after.Mass() - before.Mass()) > 1e-4 * before.Mass()) return false;
    out = std::move(candidate);
    return true;
  } catch (Standard_Failure &) {
    return false;
  }
}

/// The same body with each solid built again from its faces taken in the opposite order. Nothing about the shape
/// changes, but OCCT's round and chamfer builders walk the faces in the order the shell holds them, and a few
/// vertices (a crease that fades out into near-tangent faces) only come out right when a particular edge comes first.
/// The face merge after a boolean can leave the order the wrong way round, so a round that fails is tried once more
/// on this. False when the body holds anything but solids.
bool reverseFaceOrder(const Body &b, Body &out) {
  try {
    BRep_Builder builder;
    auto rebuilt = [&](const TopoDS_Shape &solid) {
      std::vector<TopoDS_Shape> faces;
      for (TopExp_Explorer ex(solid, TopAbs_FACE); ex.More(); ex.Next()) faces.push_back(ex.Current());
      std::reverse(faces.begin(), faces.end());
      TopoDS_Shell shell;
      builder.MakeShell(shell);
      for (const TopoDS_Shape &f : faces) builder.Add(shell, f);
      TopoDS_Solid made;
      builder.MakeSolid(made);
      builder.Add(made, shell);
      return made;
    };
    TopoDS_Shape shape;
    if (b.shape.ShapeType() == TopAbs_SOLID) {
      shape = rebuilt(b.shape);
    } else if (b.shape.ShapeType() == TopAbs_COMPOUND) {
      TopoDS_Compound compound;
      builder.MakeCompound(compound);
      for (TopoDS_Iterator it(b.shape); it.More(); it.Next()) {
        if (it.Value().ShapeType() != TopAbs_SOLID) return false;
        builder.Add(compound, rebuilt(it.Value()));
      }
      shape = compound;
    } else {
      return false;
    }
    out = makeBody(shape, namedFaces(b), "reordered");
    return true;
  } catch (Standard_Failure &) {
    return false;
  }
}

/// Whether the faults of `result` are all ones `before` already had. An extrude that left hair-thin slits through its
/// body is not a valid solid (BRepCheck refuses the faces the slits are cut into), and a round or chamfer of the
/// outline is not at fault for that: only a face that is bad now and was not bad before, or came from a bad one by
/// the operation's own history, counts against it. False when `before` was fine, or when `result` has faults that
/// are not in a face (a shell that does not close), which this does not look at.
bool onlyOldFaults(const TopoDS_Shape &before, BRepBuilderAPI_MakeShape &op, const TopoDS_Shape &result) {
  try {
    ShapeList old;
    for (TopExp_Explorer ex(before, TopAbs_FACE); ex.More(); ex.Next()) {
      if (BRepCheck_Analyzer(ex.Current()).IsValid()) continue;
      old.Append(ex.Current());
      for (const TopoDS_Shape &m : op.Modified(ex.Current())) old.Append(m);
    }
    if (old.IsEmpty()) return false;
    bool anyBad = false;
    for (TopExp_Explorer ex(result, TopAbs_FACE); ex.More(); ex.Next()) {
      if (BRepCheck_Analyzer(ex.Current()).IsValid()) continue;
      anyBad = true;
      bool known = false;
      for (const TopoDS_Shape &o : old)
        if (o.IsSame(ex.Current())) {
          known = true;
          break;
        }
      if (!known) return false;
    }
    return anyBad;
  } catch (Standard_Failure &) {
    return false;
  }
}

template <class Maker, class AddFn>
SKHandle edgeFeature(SKHandle body, const char *const *edgeNames, int count, const std::string &feat,
                            const char *kind, AddFn add, double size = 0, bool healed = false) {
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return 0;
  if (count < 1) {
    setError(std::string(kind) + " needs at least one edge");
    return 0;
  }
  // On the heap so that a builder that faulted (see runGuarded) can be left alone instead of destroyed.
  std::unique_ptr<Maker> builder(new Maker(b->shape));
  Maker &mk = *builder;
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
  std::vector<TopoDS_Edge> picked;
  for (auto &u : used) picked.push_back(TopoDS::Edge(u.first));
  // A chain with a hair-thin strip face in it fails whatever the size: leave the strip out of the body and try once more.
  auto fail = [&](const std::string &message) -> SKHandle {
    Body strippedBody;
    if (!healed && shortestChainEdge(*b, picked) < 1e-3 && healStrips(*b, strippedBody, feat + "." + kind)) {
      std::vector<std::string> kept;
      for (int k = 0; k < count; ++k)
        if (strippedBody.edgeIndex.count(edgeNames[k])) kept.push_back(edgeNames[k]);
      if (!kept.empty()) {
        std::vector<const char *> pointers;
        for (const std::string &name : kept) pointers.push_back(name.c_str());
        const SKHandle h = store(std::move(strippedBody));
        const SKHandle made = edgeFeature<Maker>(h, pointers.data(), (int)pointers.size(), feat, kind, add, size, true);
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          g_objects.erase(h);
        }
        return made;  // 0 with the reason the healed body gave, which is the one that still holds
      }
    }
    setError(message);
    return 0;
  };
  // A chamfer as big as the radius of a rounded corner it runs round is refused here, not left to OCCT: it
  // sometimes fails, but it also returns bodies that pass BRepCheck and still have the wrong shape.
  if (std::strcmp(kind, "chamfer") == 0) {
    std::string why = cornerMessageIn(*b, mk, kind, size);
    if (!why.empty()) {
      setError(why);
      return 0;
    }
  }
  if (!runGuarded([&] { mk.Build(); })) {
    builder.release();  // leaked: it is in no state to be taken apart
    setError(std::string(kind) + " could not be built: OpenCascade failed inside it. A slightly different size may work");
    return 0;
  }
  if (!mk.IsDone()) {
    std::string why = failureMessage(*b, picked, kind, size);
    return fail(why.empty() ? std::string(kind) + " failed (size too large for the adjacent faces?)" : why);
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
  // OCCT can return a body that is valid, or repairable into a valid one, and still wrong when a round is too big
  // for its faces: bigger than before although only convex edges were rounded (see allConvex).
  auto grew = [&](const TopoDS_Shape &result) {
    // Only a result that encloses more can be too big, and that shows in the faces that changed alone: the bodies'
    // own volumes (an integral over every face, helical ones included) are only needed when it does.
    // (Not for a body with a spline extrusion: the integral over those is off by a percent or two and not by the same
    // amount from one reference point to the next, so for them the volumes are compared as they always were.)
    if (!hasSplineExtrusion(b->shape) && !hasSplineExtrusion(result) && volumeChange(b->shape, result) <= 1e-9) return false;
    std::vector<TopoDS_Edge> all;
    for (auto &c : chain) all.push_back(TopoDS::Edge(c.first));
    GProp_GProps before, after;
    BRepGProp::VolumeProperties(b->shape, before);
    BRepGProp::VolumeProperties(result, after);
    return after.Mass() > before.Mass() * (1 + 1e-6) + 1e-9 && allConvex(b->shape, all);
  };
  auto tooBigMessage = [&] {
    const std::string why = failureMessage(*b, picked, kind, size);
    return why.empty() ? std::string(kind) + " failed (size too large for the adjacent faces?)" : why;
  };
  BRepCheck_Analyzer check(out.shape, true, true);  // in parallel: it takes long on a body with threads
  if (!check.IsValid()) {
    // The body may have been invalid before this (slits an extrude left): what it did itself is what is judged.
    if (onlyOldFaults(b->shape, mk, out.shape)) {
      if (grew(out.shape)) return fail(tooBigMessage());
      return store(std::move(out));
    }
    // OCCT sometimes returns a fillet's result with a shell that is not quite closed or with edge tolerances
    // gone loose (after several fillets on one body); repairing it is often enough. Face names follow the repair.
    ShapeFix_Shape fix(mk.Shape());
    fix.Perform();
    if (BRepCheck_Analyzer(fix.Shape()).IsValid()) {
      if (grew(fix.Shape())) {
        return fail(tooBigMessage());
      }
      std::vector<Named> fixedNames;
      for (const Named &n : names) fixedNames.push_back({fix.Context()->Apply(n.shape), n.name});
      return store(makeBody(fix.Shape(), fixedNames, feat + "." + kind));
    }
    std::string why = failureMessage(*b, picked, kind, size);
    return fail(why.empty() ? std::string(kind) + " produced an invalid solid" : why);
  }
  if (grew(out.shape)) return fail(tooBigMessage());
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
  if (!BRepCheck_Analyzer(b.shape, true, true).IsValid()) {
    setError(failure);
    return 0;
  }
  return store(std::move(b));
}

/// The outward normal of a planar face. A plane's own axis is not enough: its coordinate system can be
/// left-handed (booleans and chamfers make such planes), and then the surface normal is X × Y, the opposite of
/// its axis. Taking the axis there points a sketch's camera into the solid.
gp_Dir planeNormal(const TopoDS_Face &f, const gp_Pln &plane) {
  const gp_Ax3 &pos = plane.Position();
  gp_Dir n = pos.XDirection().Crossed(pos.YDirection());
  if (f.Orientation() == TopAbs_REVERSED) n.Reverse();
  return n;
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

/// What lies beyond the end of a round face, told from the flat face across its end edge (a hole's mouth or floor, a
/// shaft's tip or shoulder), which takes no time however many faces the body has: 1 = air, 0 = material, -1 = it
/// can't be told this way (the end is a cone, a fillet, several faces...). `end` is a point on the end, `outward` the
/// unit direction away from the face along its axis.
int endBeyond(const Body &b, const TopoDS_Face &face, const gp_Pnt &end, const gp_Vec &outward) {
  TopoDS_Shape across;
  for (TopExp_Explorer ex(face, TopAbs_EDGE); ex.More(); ex.Next()) {
    const TopoDS_Edge &e = TopoDS::Edge(ex.Current());
    if (BRep_Tool::Degenerated(e)) continue;
    BRepAdaptor_Curve c(e);
    bool onEnd = true;  // the edge lies in the plane across the axis at this end
    for (double t : {0.0, 0.5, 1.0}) {
      const gp_Pnt p = c.Value(c.FirstParameter() + t * (c.LastParameter() - c.FirstParameter()));
      if (std::abs(gp_Vec(end, p).Dot(outward)) > 1e-6) onEnd = false;
    }
    if (!onEnd) continue;
    TopoDS_Shape other;
    int count = 0;
    for (int i = 1; i <= b.faces.Extent(); ++i) {
      const TopoDS_Shape &g = b.faces(i);
      if (g.IsSame(face)) continue;
      for (TopExp_Explorer eg(g, TopAbs_EDGE); eg.More(); eg.Next())
        if (eg.Current().IsSame(e)) { other = g; ++count; break; }
    }
    if (count != 1) return -1;
    if (!across.IsNull() && !across.IsSame(other)) return -1;
    across = other;
  }
  if (across.IsNull()) return -1;
  const TopoDS_Face &g = TopoDS::Face(across);
  BRepAdaptor_Surface s(g);
  if (s.GetType() != GeomAbs_Plane) return -1;
  const double along = gp_Vec(planeNormal(g, s.Plane())).Dot(outward);
  if (std::abs(along) < 0.999) return -1;
  return along > 0 ? 1 : 0;
}

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
    const int beyond = endBeyond(b, face, end, outward);
    if (beyond >= 0) return beyond == 1;
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

/// A solid and the names its faces get when it is used as the tool of a boolean.
struct NamedTool {
  TopoDS_Shape shape;
  std::vector<Named> faces;
};

/// A tool whose faces all get one name.
NamedTool namedTool(const TopoDS_Shape &shape, const std::string &name) {
  NamedTool t{shape, {}};
  for (TopExp_Explorer ex(shape, TopAbs_FACE); ex.More(); ex.Next()) t.faces.push_back({ex.Current(), name});
  return t;
}

/// A boolean on a shape and its face names with one or more tools at once, carrying the names of all the operands.
/// Several tools cost little more than one: what takes the time is going through the shape.
bool namedBooleanMany(TopoDS_Shape &shape, std::vector<Named> &names, const std::vector<NamedTool> &tools, SKBooleanOp op) {
  std::unique_ptr<BRepAlgoAPI_BooleanOperation> bop;
  switch (op) {
    case SK_FUSE: bop = std::make_unique<BRepAlgoAPI_Fuse>(); break;
    case SK_CUT: bop = std::make_unique<BRepAlgoAPI_Cut>(); break;
    case SK_COMMON: bop = std::make_unique<BRepAlgoAPI_Common>(); break;
  }
  ShapeList args, toolList;
  args.Append(shape);
  for (const NamedTool &t : tools) toolList.Append(t.shape);
  bop->SetArguments(args);
  bop->SetTools(toolList);
  bop->SetRunParallel(true);
  bop->Build();
  if (!bop->IsDone() || bop->HasErrors()) return false;
  std::vector<Named> out;
  carry(*bop, names, out);  // the body's names first: they win on merged faces
  for (const NamedTool &t : tools) carry(*bop, t.faces, out);
  shape = bop->Shape();
  names = std::move(out);
  return true;
}

/// A boolean on a shape and its face names, carrying the names of both operands.
bool namedBoolean(TopoDS_Shape &shape, std::vector<Named> &names, const TopoDS_Shape &tool, const std::string &toolName,
                  SKBooleanOp op) {
  return namedBooleanMany(shape, names, {namedTool(tool, toolName)}, op);
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

/// The parts of a thread that depend only on its own sizes: the helical groove, and (where the thread is rebuilt
/// as a ring) the ring of the thread zone with the groove taken out of it. They take over a tenth of a second
/// each and are the same for every hole of one size and every rebuild of a part, so they are built once, with the
/// axis at the origin, and moved into place.
struct ThreadSpec {
  bool internal = false, leftHanded = false;
  double R = 0, rMajor = 0, pitch = 0, length = 0, z0 = 0, z1 = 0;
  std::array<double, 8> key() const {
    return {internal ? 1.0 : 0.0, leftHanded ? 1.0 : 0.0, R, rMajor, pitch, length, z0, z1};
  }
};

struct ThreadParts {
  TopoDS_Shape sweep;           // the groove, cut to the thread zone
  TopoDS_Shape fill;            // the threaded ring; null when the thread has none
  std::vector<Named> fillNames; // its faces: "C" for the crest, "T" for the groove
  double fillVolume = 0;
};

enum class ThreadFailure { None, Helix, Cut };

std::shared_ptr<const ThreadParts> buildThreadParts(const ThreadSpec &t, const gp_Ax3 &f, ThreadFailure &failure) {
  const double P = t.pitch, rMajor = t.rMajor, R = t.R, L = t.length;
  const double rMinor = rMajor - 0.541265877365 * P;  // basic profile: 5/8 of the 60° triangle deep
  const double tol = 1e-4;
  // The groove between the teeth (ISO 68 basic profile: flats of P/8 at the major diameter and P/4 at
  // the minor, 30° flanks), reaching past the crests so the cut is clean. The flanks run on a little
  // past the crest diameter before the groove turns square: a groove edge lying exactly on the
  // crest cylinder (where the rings below have their faces) makes OCCT's booleans quietly fail.
  const double t30 = std::tan(M_PI / 6);
  std::vector<std::pair<double, double>> groove;
  if (t.internal) {
    // A blind hole drilled at exactly the major diameter has the edge where its wall meets the drill
    // point on the groove's outer edge, and the fuse below fails on the shared edge: take the groove
    // 2 µm wider in that one case.
    const double rOut = std::abs(R - rMajor) < 1e-4 ? rMajor + 2e-3 : rMajor;
    auto z = [&](double r) { return P / 16 + (rMajor - r) * t30; };  // half-width at radius r
    const double r1 = rMinor - P / 20, r2 = rMinor - P / 4;
    groove = {{r2, -z(r1)}, {r1, -z(r1)}, {rOut, -z(rMajor)}, {rOut, z(rMajor)}, {r1, z(r1)}, {r2, z(r1)}};
  } else {
    auto z = [&](double r) { return P / 8 + (r - rMinor) * t30; };
    const double r1 = rMajor + P / 20, r2 = rMajor + P / 4;
    groove = {{rMinor, -z(rMinor)}, {r1, -z(r1)}, {r2, -z(r1)}, {r2, z(r1)}, {r1, z(r1)}, {rMinor, z(rMinor)}};
  }
  auto parts = std::make_shared<ThreadParts>();
  std::vector<Named> none;
  parts->sweep = TopoDS_Shape();
  if (!helicalSweep(f, P, t.z0 - P, t.z1 + P, t.leftHanded, groove, parts->sweep)) {
    failure = ThreadFailure::Helix;
    return nullptr;
  }
  if (!namedBoolean(parts->sweep, none, ring(f, 0, rMajor + P, t.z0, t.z1), "", SK_COMMON)) {
    failure = ThreadFailure::Helix;
    return nullptr;
  }
  // No face of the groove may lie on a face of the body (the original round face is often exactly at
  // a crest or root diameter): OCCT's booleans can then quietly return the body unchanged, or empty.
  // A hole is bored out past the major diameter and the whole thread zone put back as a ring from the minor
  // diameter out into the wall, with the groove taken out of it. A shaft thinner than the thread is filled
  // out to the major diameter the same way.
  if (t.internal) {
    const double rBore = std::max(R, rMajor) + P / 4;
    parts->fill = ring(f, rMinor, rBore + P / 4, 0, L);
  } else if (R < rMajor - tol) {
    parts->fill = ring(f, R * 0.5, rMajor, 0, L);
  }
  if (!parts->fill.IsNull()) {
    for (TopExp_Explorer ex(parts->fill, TopAbs_FACE); ex.More(); ex.Next()) parts->fillNames.push_back({ex.Current(), "C"});
    if (!namedBoolean(parts->fill, parts->fillNames, parts->sweep, "T", SK_CUT)) {
      failure = ThreadFailure::Cut;
      return nullptr;
    }
    GProp_GProps g;
    BRepGProp::VolumeProperties(parts->fill, g);
    parts->fillVolume = g.Mass();
    if (parts->fillVolume < 1e-9) {
      failure = ThreadFailure::Cut;
      return nullptr;
    }
  }
  return parts;
}

/// The move from the origin frame (axis along z, x along x) onto `f`; false if it can't be worked out.
bool placement(const gp_Ax3 &f, gp_Trsf &out) {
  const gp_Pnt o = f.Location();
  const gp_Pnt z = o.Translated(gp_Vec(f.Direction())), x = o.Translated(gp_Vec(f.XDirection()));
  auto moves = [&](const gp_Trsf &t) {
    return gp_Pnt(0, 0, 0).Transformed(t).Distance(o) < 1e-9 && gp_Pnt(0, 0, 1).Transformed(t).Distance(z) < 1e-9 &&
           gp_Pnt(1, 0, 0).Transformed(t).Distance(x) < 1e-9;
  };
  gp_Trsf t;
  t.SetTransformation(f);  // this one, or its inverse, depending on the direction OCCT means
  if (moves(t)) { out = t; return true; }
  if (moves(t.Inverted())) { out = t.Inverted(); return true; }
  return false;
}

/// The thread's parts moved onto frame `f`. `sweep` is only moved when `needSweep` (a hole's thread uses the groove only
/// inside its ring).
struct PlacedThread {
  TopoDS_Shape sweep, fill;
  std::vector<Named> fillNames;  // the ring's faces: "C" and "T" as in ThreadParts
  double fillVolume = 0;
};

gp_Ax3 originFrame() { return gp_Ax3(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1), gp_Dir(1, 0, 0)); }

using ThreadPartsPtr = std::shared_ptr<const ThreadParts>;

/// The parts of each size in `specs`, from the cache when the size has been built before. The sizes that haven't are
/// built side by side (each takes a tenth of a second or more, and a thread feature on several holes of different
/// sizes needs one for each). A size that can't be built comes back null, with the reason in `failures`.
std::vector<ThreadPartsPtr> threadPartsFor(const std::vector<ThreadSpec> &specs, std::vector<ThreadFailure> &failures) {
  static std::mutex mutex;
  static std::map<std::array<double, 8>, ThreadPartsPtr> cache;
  std::vector<ThreadPartsPtr> parts(specs.size());
  failures.assign(specs.size(), ThreadFailure::None);
  std::vector<size_t> toBuild;  // the first spec of each size that isn't cached
  {
    std::lock_guard<std::mutex> lock(mutex);
    for (size_t i = 0; i < specs.size(); ++i) {
      auto it = cache.find(specs[i].key());
      if (it != cache.end()) {
        parts[i] = it->second;
      } else if (std::none_of(toBuild.begin(), toBuild.end(), [&](size_t j) { return specs[j].key() == specs[i].key(); })) {
        toBuild.push_back(i);
      }
    }
  }
  std::vector<ThreadPartsPtr> built(toBuild.size());
  std::vector<ThreadFailure> builtFailures(toBuild.size(), ThreadFailure::None);
  auto buildOne = [&](int k) {
    try {
      built[k] = buildThreadParts(specs[toBuild[k]], originFrame(), builtFailures[k]);
    } catch (...) {  // nothing may escape from a worker thread
      built[k] = nullptr;
      builtFailures[k] = ThreadFailure::Helix;
    }
    if (!built[k] && builtFailures[k] == ThreadFailure::None) builtFailures[k] = ThreadFailure::Helix;
  };
  if (toBuild.size() == 1) buildOne(0);
  else if (toBuild.size() > 1) OSD_Parallel::For(0, (int)toBuild.size(), buildOne);
  {
    std::lock_guard<std::mutex> lock(mutex);
    if (cache.size() + toBuild.size() > 32) cache.clear();  // many sizes in one session: start over
    for (size_t k = 0; k < toBuild.size(); ++k)
      if (built[k]) cache[specs[toBuild[k]].key()] = built[k];
  }
  for (size_t i = 0; i < specs.size(); ++i) {
    if (parts[i]) continue;
    for (size_t k = 0; k < toBuild.size(); ++k) {
      if (specs[toBuild[k]].key() != specs[i].key()) continue;
      parts[i] = built[k];
      failures[i] = builtFailures[k];
    }
  }
  return parts;
}

bool placeThread(const ThreadPartsPtr &parts, const ThreadSpec &t, const gp_Ax3 &f, bool needSweep, PlacedThread &out,
                 ThreadFailure &failure) {
  gp_Trsf move;
  if (!placement(f, move)) {  // not expected: build it in place
    auto built = buildThreadParts(t, f, failure);
    if (!built) return false;
    out = {built->sweep, built->fill, built->fillNames, built->fillVolume};
    return true;
  }
  if (needSweep) {
    BRepBuilderAPI_Transform tr(parts->sweep, move, true);
    if (!tr.IsDone()) { failure = ThreadFailure::Helix; return false; }
    out.sweep = tr.Shape();
  }
  if (!parts->fill.IsNull()) {
    BRepBuilderAPI_Transform tr(parts->fill, move, true);
    if (!tr.IsDone()) { failure = ThreadFailure::Cut; return false; }
    out.fill = tr.Shape();
    for (const Named &n : parts->fillNames) out.fillNames.push_back({tr.ModifiedShape(n.shape), n.name});
    out.fillVolume = parts->fillVolume;
  }
  return true;
}

/// One round face to thread: where it is and the thread's sizes.
struct ThreadJob {
  std::string feat, crest;  // the names of the new faces: "<feat>.thread" and the crest's
  Cylinder c;
  ThreadSpec spec;
  gp_Ax3 frame;  // the axis, from the end the thread starts at
  double R = 0, rMajor = 0, pitch = 0;

  /// The radius of the ring-shaped tool that bores a hole out (or turns a shaft down) before the thread goes in.
  double rBore() const { return std::max(R, rMajor) + pitch / 4; }
  /// The radius that holds all the thread cuts, with a little to spare.
  double reach() const { return std::max(R, rMajor) + pitch + 1e-3; }
};

/// Works out the thread to cut into one round face. False, with the error set, if the face is no round face or the
/// thread does not suit it.
bool planThread(const Body &b, const char *faceName, double majorDiameter, double pitch, double length, bool flipped,
                bool leftHanded, const std::string &feat, ThreadJob &job) {
  auto it = b.faceIndex.find(faceName);
  if (it == b.faceIndex.end()) {
    setError(std::string("face not found: ") + faceName);
    return false;
  }
  Cylinder c;
  if (!cylinderOf(b, TopoDS::Face(b.faces(it->second + 1)), flipped, c)) return false;
  const double P = pitch, rMajor = majorDiameter / 2;
  const double rMinor = rMajor - 0.541265877365 * P;  // basic profile: 5/8 of the 60° triangle deep
  if (!(P > Precision::Confusion()) || !(rMinor > Precision::Confusion())) {
    setError("the thread's diameter and pitch must be positive, and the pitch small enough for the diameter");
    return false;
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
    return false;
  }
  const bool full = length <= 0 || length >= c.length - 1e-6;
  const double L = full ? c.length : length;
  if (length > c.length + 1e-6) {
    char msg[120];
    std::snprintf(msg, sizeof msg, "the thread is longer than the round face (%.4g mm)", c.length);
    setError(msg);
    return false;
  }
  if (L < P) {
    setError("the thread must be at least one pitch long");
    return false;
  }
  job.feat = feat;
  job.crest = feat + ".thread.crest";
  job.c = c;
  job.frame = gp_Ax3(c.start, c.dir, c.radial);
  job.R = R;
  job.rMajor = rMajor;
  job.pitch = P;
  job.spec.internal = c.internal;
  job.spec.leftHanded = leftHanded;
  job.spec.R = R;
  job.spec.rMajor = rMajor;
  job.spec.pitch = P;
  job.spec.length = L;
  // Past an open end the thread runs out into the air; at a shoulder or a hole's floor it stops flat.
  job.spec.z0 = c.freeStart ? -P : 0;
  job.spec.z1 = full && c.freeEnd ? L + P : L;
  return true;
}

/// The shortest distance between the segments p1-q1 and p2-q2.
double segmentDistance(const gp_Pnt &p1, const gp_Pnt &q1, const gp_Pnt &p2, const gp_Pnt &q2) {
  const gp_Vec d1(p1, q1), d2(p2, q2), r(p2, p1);
  const double a = d1.Dot(d1), e = d2.Dot(d2), f = d2.Dot(r);
  double s = 0, t = 0;
  if (a <= 1e-18 && e <= 1e-18) return p1.Distance(p2);
  if (a <= 1e-18) {
    t = std::clamp(f / e, 0.0, 1.0);
  } else {
    const double c = d1.Dot(r);
    if (e <= 1e-18) {
      s = std::clamp(-c / a, 0.0, 1.0);
    } else {
      const double b = d1.Dot(d2), denom = a * e - b * b;
      s = denom > 1e-12 * a * e ? std::clamp((b * f - c * e) / denom, 0.0, 1.0) : 0.0;
      t = (b * s + f) / e;
      if (t < 0) { t = 0; s = std::clamp(-c / a, 0.0, 1.0); }
      else if (t > 1) { t = 1; s = std::clamp((b - c) / a, 0.0, 1.0); }
    }
  }
  return p1.Translated(d1 * s).Distance(p2.Translated(d2 * t));
}

/// Whether no thread's cuts reach those of another, so that they can all be made in one go as if one after the other.
bool threadsApart(const std::vector<ThreadJob> &jobs) {
  for (size_t i = 0; i < jobs.size(); ++i)
    for (size_t j = i + 1; j < jobs.size(); ++j) {
      auto axis = [](const ThreadJob &t, double z) { return t.c.start.Translated(gp_Vec(t.c.dir) * z); };
      const double gap = segmentDistance(axis(jobs[i], jobs[i].spec.z0), axis(jobs[i], jobs[i].spec.z1),
                                         axis(jobs[j], jobs[j].spec.z0), axis(jobs[j], jobs[j].spec.z1));
      if (gap <= jobs[i].reach() + jobs[j].reach()) return false;
    }
  return true;
}

/// Cuts the threads into the body, all in the same few passes over it: what a thread costs is mostly going through
/// the whole body (the more threads it has, the longer), and a pass with several rings takes little more than one with
/// a single ring. The faces of one thread are told apart from the others' by the feature names in `jobs`.
SKHandle threadsInto(const Body &b, std::vector<ThreadJob> &jobs) {
  const double tol = 1e-4;
  std::vector<ThreadSpec> specs;
  for (const ThreadJob &j : jobs) specs.push_back(j.spec);
  std::vector<ThreadFailure> failures;
  const std::vector<ThreadPartsPtr> parts = threadPartsFor(specs, failures);
  std::vector<PlacedThread> placed(jobs.size());
  for (size_t i = 0; i < jobs.size(); ++i) {
    ThreadFailure failure = failures[i];
    // A hole's groove is only used inside its ring; a shaft's is cut from the shaft itself.
    if (parts[i] && placeThread(parts[i], jobs[i].spec, jobs[i].frame, !jobs[i].c.internal, placed[i], failure)) continue;
    setError(failure == ThreadFailure::Helix ? "could not build the thread's helix" : "could not cut the thread");
    return 0;
  }
  TopoDS_Shape shape = b.shape;
  std::vector<Named> names = namedFaces(b);
  // Bore the holes out past the major diameter (their rings go back in below) and turn thicker shafts down to it.
  std::vector<NamedTool> turn, grooves, fills;
  for (size_t i = 0; i < jobs.size(); ++i) {
    const ThreadJob &j = jobs[i];
    if (j.c.internal) turn.push_back(namedTool(ring(j.frame, 0, j.rBore(), j.spec.z0, j.spec.z1), j.crest));
    else if (j.R > j.rMajor + tol) turn.push_back(namedTool(ring(j.frame, j.rMajor, j.R + j.pitch, j.spec.z0, j.spec.z1), j.crest));
    if (!j.c.internal) grooves.push_back(namedTool(placed[i].sweep, j.feat + ".thread"));
    if (!placed[i].fill.IsNull()) {
      // A thinner shaft is filled out below, a hole's ring is put back.
      NamedTool fill{placed[i].fill, {}};
      for (const Named &n : placed[i].fillNames) fill.faces.push_back({n.shape, n.name == "T" ? j.feat + ".thread" : j.crest});
      fills.push_back(std::move(fill));
    }
  }
  bool ok = true;
  if (!turn.empty()) ok = namedBooleanMany(shape, names, turn, SK_CUT);
  if (ok && !grooves.empty()) ok = namedBooleanMany(shape, names, grooves, SK_CUT);
  if (ok && !fills.empty()) ok = namedBooleanMany(shape, names, fills, SK_FUSE);
  if (!ok) {
    setError("could not cut the thread");
    return 0;
  }
  TopoDS_Shape result = unify(shape, names);
  Body done = makeBody(result, names, jobs.front().feat + ".thread");
  // OCCT's booleans can quietly give the body back unchanged: every thread has to have left its faces in the result.
  for (const ThreadJob &j : jobs) {
    const std::string own = j.feat + ".thread";
    const bool found = std::any_of(done.faceNames.begin(), done.faceNames.end(),
                                   [&](const std::string &n) { return n == own || n.rfind(own + "#", 0) == 0; });
    if (!found) {
      setError("could not cut the thread");
      return 0;
    }
  }
  if (!BRepCheck_Analyzer(done.shape, true, true).IsValid()) {
    setError("the thread produced an invalid solid");
    return 0;
  }
  return store(std::move(done));
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

/// Joins the smooth Bézier pieces along a region's border into single spline edges, so that an extrude gives one
/// side face for the whole run (a run of pieces, like an offset curve, would otherwise leave a seam at every joint,
/// which shows in the body and ruins anything projected onto it). The merged edge takes the tag of the first
/// piece that went into it; lines, arcs, sharp corners and the pieces of a curve that was split (or of a letter)
/// are left alone. The run is refitted as one curve that is smooth all along, within a ten-thousandth of a
/// millimetre: a surface that is only tangent-continuous at the joints can't be thickened by OCCT, so a relief
/// projected onto it would fail. Gives back `face` unchanged when anything goes wrong.
static TopoDS_Face mergeSmoothBeziers(const TopoDS_Face &face, std::vector<Named> &pieces) {
  try {
    struct Item {
      TopoDS_Edge edge;
      std::string tag;
      bool eligible = false;
      gp_Vec startDir, endDir;  // travel directions at the ends (unit length)
      TopoDS_Vertex first, last;  // travel ends
    };
    std::map<std::string, int> uses;
    auto tagOf = [&](const TopoDS_Shape &e) {
      for (const Named &piece : pieces)
        if (piece.shape.IsSame(e)) return piece.name;
      return std::string();
    };
    for (TopExp_Explorer ex(face, TopAbs_EDGE); ex.More(); ex.Next()) ++uses[tagOf(ex.Current())];

    Handle(Geom_Surface) surface;
    TopLoc_Location placed;
    surface = BRep_Tool::Surface(face, placed);
    std::vector<TopoDS_Wire> wires;
    std::vector<Named> named;  // the edges of the new wires and the tags they carry
    bool merged = false;
    const TopoDS_Wire outer = BRepTools::OuterWire(face);
    TopoDS_Wire outerOut;
    for (TopExp_Explorer wx(face, TopAbs_WIRE); wx.More(); wx.Next()) {
      const TopoDS_Wire wire = TopoDS::Wire(wx.Current());
      std::vector<Item> items;
      for (BRepTools_WireExplorer we(wire, face); we.More(); we.Next()) {
        Item it;
        it.edge = we.Current();
        it.tag = tagOf(it.edge);
        double f, l;
        Handle(Geom_BezierCurve) c = Handle(Geom_BezierCurve)::DownCast(BRep_Tool::Curve(it.edge, f, l));
        const bool reversed = it.edge.Orientation() == TopAbs_REVERSED;
        gp_Pnt pt;
        gp_Vec d0, d1;
        if (!c.IsNull() && !it.tag.empty() && uses[it.tag] == 1) {
          c->D1(f, pt, d0);
          c->D1(l, pt, d1);
          if (d0.Magnitude() > 1e-9 && d1.Magnitude() > 1e-9) {
            it.eligible = true;
            it.startDir = (reversed ? -d1 : d0).Normalized();
            it.endDir = (reversed ? -d0 : d1).Normalized();
          }
        }
        TopoDS_Vertex v1, v2;
        TopExp::Vertices(it.edge, v1, v2, true);  // by travel
        it.first = v1;
        it.last = v2;
        items.push_back(it);
      }
      const int n = (int)items.size();
      auto joins = [&](int a, int b) {
        return items[a].eligible && items[b].eligible && items[a].last.IsSame(items[b].first) &&
               items[a].endDir.Dot(items[b].startDir) > 1 - 1e-6;
      };
      int start = -1;
      for (int k = 0; k < n && start < 0; ++k)
        if (!joins((k + n - 1) % n, k)) start = k;
      TopoDS_Wire out;
      BRep_Builder bb;
      bb.MakeWire(out);
      if (start < 0 || n < 2) {  // nothing to join, or a loop that is smooth all the way round
        for (const Item &it : items) {
          bb.Add(out, it.edge);
          named.push_back({it.edge, it.tag});
        }
      } else {
        for (int k = 0; k < n;) {
          const int i = (start + k) % n;
          int len = 1;
          while (k + len < n && joins((start + k + len - 1) % n, (start + k + len) % n)) ++len;
          if (len == 1) {
            bb.Add(out, items[i].edge);
            named.push_back({items[i].edge, items[i].tag});
            k += 1;
            continue;
          }
          // The exact curve of the run, in travel order, then one smooth refit of it.
          GeomConvert_CompCurveToBSplineCurve join;
          bool ok = true;
          for (int m = 0; m < len && ok; ++m) {
            const Item &it = items[(start + k + m) % n];
            double f, l;
            Handle(Geom_Curve) c = BRep_Tool::Curve(it.edge, f, l);
            Handle(Geom_TrimmedCurve) piece = new Geom_TrimmedCurve(c, f, l);
            if (it.edge.Orientation() == TopAbs_REVERSED) piece->Reverse();
            Handle(Geom_BSplineCurve) spline = GeomConvert::CurveToBSplineCurve(piece);
            ok = m == 0 ? join.Add(spline, 1e-6) : join.Add(spline, 1e-6, true);
          }
          if (!ok) return face;
          Handle(Geom_BSplineCurve) exact = join.BSplineCurve();
          const int samples = std::max(120, 40 * exact->NbKnots());
          NCollection_Array1<gp_Pnt> through(1, samples);
          for (int q = 0; q < samples; ++q)
            through(q + 1) = exact->Value(exact->FirstParameter() + (exact->LastParameter() - exact->FirstParameter()) * q / (samples - 1));
          GeomAPI_PointsToBSpline approx(through, 3, 5, GeomAbs_C2, 1e-4);
          if (!approx.IsDone()) return face;
          BRepBuilderAPI_MakeEdge mk(Handle(Geom_Curve)(approx.Curve()), items[i].first, items[(start + k + len - 1) % n].last);
          if (!mk.IsDone()) return face;
          bb.Add(out, mk.Edge());
          named.push_back({mk.Edge(), items[i].tag});  // the first piece's tag
          merged = true;
          k += len;
        }
      }
      out.Closed(true);
      if (wire.IsSame(outer)) outerOut = out;
      else wires.push_back(out);
    }
    if (!merged) return face;
    TopoDS_Face rebuilt;
    BRep_Builder bb;
    bb.MakeFace(rebuilt, surface, placed, BRep_Tool::Tolerance(face));
    bb.Add(rebuilt, outerOut);
    for (const TopoDS_Wire &w : wires) bb.Add(rebuilt, w);
    rebuilt.Orientation(face.Orientation());
    ShapeFix_Face fix(rebuilt);
    fix.SetContext(new ShapeBuild_ReShape);
    fix.Perform();
    const TopoDS_Face done = fix.Face();
    if (done.IsNull()) return face;
    GProp_GProps before, after;
    // (The adaptive form: the plain one is a few tenths of a percent off on a spline boundary.)
    BRepGProp::SurfaceProperties(face, before, 1e-7);
    BRepGProp::SurfaceProperties(done, after, 1e-7);
    if (!BRepCheck_Analyzer(done).IsValid() ||
        std::fabs(after.Mass() - before.Mass()) > 5e-4 * before.Mass() + 1e-9)
      return face;
    for (const Named &n : named) {
      const TopoDS_Shape now = fix.Context()->Apply(n.shape);
      if (!n.name.empty()) pieces.push_back({now, n.name});
    }
    return done;
  } catch (...) {
    return face;
  }
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
    r.face = mergeSmoothBeziers(f, s->pieces);
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

/// A prism of `base` pushed along `dir` by `length` (negative: against it), its flat caps named `baseName` and
/// `topName` and its side faces named after the edges they grew from. A `taper` (radians, positive: the sides
/// lean out as they go, negative: in) leans every side face about the base's plane. Returns the solid, or a null
/// shape with the error set.
static TopoDS_Shape prismPiece(const TopoDS_Face &base, const Profile &p, const TopLoc_Location &placed, const gp_Dir &dir,
                               double length, double taper, const std::string &baseName, const std::string &topName,
                               const std::string &sidePrefix, std::vector<Named> &names) {
  BRepPrimAPI_MakePrism prism(base, gp_Vec(dir) * length);
  prism.Build();
  if (!prism.IsDone()) {
    setError("extrude failed");
    return TopoDS_Shape();
  }
  std::unique_ptr<BRepOffsetAPI_DraftAngle> draft;
  if (std::fabs(taper) > 1e-9) {
    BRepAdaptor_Surface plane(base);
    if (plane.GetType() != GeomAbs_Plane) {
      setError("only a flat profile can be tapered");
      return TopoDS_Shape();
    }
    const gp_Dir pull = length > 0 ? dir : dir.Reversed();
    const gp_Pln neutral(plane.Plane().Location(), pull);
    draft = std::make_unique<BRepOffsetAPI_DraftAngle>(prism.Shape());
    // A positive draft angle takes matter away on the side the direction points to; a taper that leans out adds it.
    for (TopExp_Explorer ex(base, TopAbs_EDGE); ex.More(); ex.Next())
      for (const TopoDS_Shape &side : prism.Generated(ex.Current())) {
        draft->Add(TopoDS::Face(side), pull, -taper, neutral);
        if (!draft->AddDone()) {
          setError("this shape can't be tapered that far");
          return TopoDS_Shape();
        }
      }
    draft->Build();
    if (!draft->IsDone()) {
      setError("this shape can't be tapered that far");
      return TopoDS_Shape();
    }
  }
  auto after = [&](const TopoDS_Shape &s) { return draft ? draft->ModifiedShape(s) : s; };
  names.push_back({after(prism.FirstShape()), baseName});
  names.push_back({after(prism.LastShape()), topName});
  for (TopExp_Explorer ex(base, TopAbs_EDGE); ex.More(); ex.Next()) {
    std::string tag = "?";
    for (const Named &t : p.edgeTags)
      if (t.shape.Moved(placed).IsSame(ex.Current())) {
        tag = t.name;
        break;
      }
    for (const TopoDS_Shape &side : prism.Generated(ex.Current())) names.push_back({after(side), sidePrefix + tag});
  }
  return draft ? draft->Shape() : prism.Shape();
}

SKHandle sk_extrude(const SKHandle *profiles, int count, double dx, double dy, double dz, double distance,
                    double distanceBack, const char *featureId) {
  return sk_extrude_tapered(profiles, count, dx, dy, dz, distance, distanceBack, 0, featureId);
}

SKHandle sk_extrude_tapered(const SKHandle *profiles, int count, double dx, double dy, double dz, double distance,
                            double distanceBack, double taper, const char *featureId) {
  return sk_extrude_from(profiles, count, dx, dy, dz, 0, distance, distanceBack, taper, featureId);
}

SKHandle sk_extrude_from(const SKHandle *profiles, int count, double dx, double dy, double dz, double startOffset,
                         double distance, double distanceBack, double taper, const char *featureId) {
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
  if (std::fabs(taper) >= M_PI / 2 - 1e-3) {
    setError("the taper angle must be under 90 degrees");
    return 0;
  }
  gp_Dir dir(dx, dy, dz);
  gp_Trsf shift;
  shift.SetTranslation(gp_Vec(dir) * (startOffset - distanceBack));
  TopLoc_Location loc(shift);
  gp_Trsf carry0;
  carry0.SetTranslation(gp_Vec(dir) * startOffset);
  const TopLoc_Location start(carry0);  // where the profile's plane is carried to
  // A taper reaches out from the sketch plane each way: two cones that meet there, not one that leans.
  const bool twoCones = std::fabs(taper) > 1e-9 && distance > Precision::Confusion() && distanceBack > Precision::Confusion();

  std::vector<TopoDS_Shape> solids;
  std::vector<Named> names;
  for (int k = 0; k < count; ++k) {
    Profile *p;
    auto keep = lookup(profiles[k], p);
    if (!p) return 0;
    if (twoCones) {
      std::vector<Named> pieceNames;
      const TopoDS_Face base = TopoDS::Face(p->face.Moved(start));
      TopoDS_Shape fwd = prismPiece(base, *p, start, dir, distance, taper, feat + ".mid", feat + ".end", feat + ".side.",
                                    pieceNames);
      if (fwd.IsNull()) return 0;
      TopoDS_Shape back = prismPiece(base, *p, start, dir.Reversed(), distanceBack, taper, feat + ".mid",
                                     feat + ".start", feat + ".side.back.", pieceNames);
      if (back.IsNull()) return 0;
      BRepAlgoAPI_Fuse fuse(fwd, back);
      if (!fuse.IsDone() || fuse.HasErrors()) {
        setError("could not join the two halves of the extrude");
        return 0;
      }
      std::vector<Named> carried;
      carry(fuse, pieceNames, carried);
      solids.push_back(unify(fuse.Shape(), carried));
      for (Named &n : carried) names.push_back(std::move(n));
      continue;
    }
    TopoDS_Face f = TopoDS::Face(p->face.Moved(loc));
    // Negative length flips which cap is which; keep "start" at the -distanceBack end.
    TopoDS_Shape piece = prismPiece(f, *p, loc, dir, length, taper, feat + (length > 0 ? ".start" : ".end"),
                                    feat + (length > 0 ? ".end" : ".start"), feat + ".side.", names);
    if (piece.IsNull()) return 0;
    solids.push_back(piece);
  }

  TopoDS_Shape result = solids[0];
  // Pieces that don't touch (the letters of a text, say) need no merging: they go into the body
  // as they are, which is what merging would give, only much faster. Pieces whose boxes overlap
  // are told apart from the rest, and only each such group is merged: one pair of kerned letters
  // must not make the whole line of text pay for a merge.
  const size_t n = solids.size();
  std::vector<Bnd_Box> boxes(n);
  for (size_t k = 0; k < n; ++k) BRepBndLib::Add(solids[k], boxes[k]);
  std::vector<size_t> group(n);
  for (size_t k = 0; k < n; ++k) group[k] = k;
  auto root = [&](size_t k) {
    while (group[k] != k) k = group[k] = group[group[k]];
    return k;
  };
  for (size_t i = 0; i < n; ++i)
    for (size_t j = i + 1; j < n; ++j) {
      Bnd_Box bi = boxes[i];
      bi.Enlarge(1e-6);
      if (!bi.IsOut(boxes[j])) group[root(j)] = root(i);
    }
  std::vector<std::vector<size_t>> clusters;  // in the order their first piece comes
  {
    std::vector<int> slot(n, -1);
    for (size_t k = 0; k < n; ++k) {
      const size_t r = root(k);
      if (slot[r] < 0) {
        slot[r] = (int)clusters.size();
        clusters.emplace_back();
      }
      clusters[slot[r]].push_back(k);
    }
  }
  if (n > 1) {
    std::vector<TopoDS_Shape> parts;
    for (const std::vector<size_t> &c : clusters) {
      if (c.size() == 1) {
        parts.push_back(solids[c[0]]);
        continue;
      }
      BRepAlgoAPI_Fuse fuse;
      ShapeList args, tools;
      args.Append(solids[c[0]]);
      for (size_t k = 1; k < c.size(); ++k) tools.Append(solids[c[k]]);
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
      parts.push_back(unify(fuse.Shape(), names));
    }
    if (parts.size() == 1) {
      result = parts[0];
    } else {
      TopoDS_Compound all;
      BRep_Builder bb;
      bb.MakeCompound(all);
      for (const TopoDS_Shape &part : parts) bb.Add(all, part);
      result = all;
    }
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

/// A profile's hole wire holds its circle with the edge flagged reversed (the hole runs clockwise inside the face).
/// Lofting that gives a bore whose surfaces OCCT's chamfer and fillet reject, so a single-edge wire like that is
/// rebuilt with the reversal in its curve instead. Returns the wire to loft; `edge` is set to the profile's own edge.
TopoDS_Wire forwardWire(const TopoDS_Wire &w, TopoDS_Edge &edge) {
  TopExp_Explorer ex(w, TopAbs_EDGE);
  edge = TopoDS::Edge(ex.Current());
  ex.Next();
  if (ex.More() || edge.Orientation() != TopAbs_REVERSED) return w;
  TopLoc_Location loc;
  double first, last;
  Handle(Geom_Curve) c = BRep_Tool::Curve(edge, loc, first, last);
  if (c.IsNull()) return w;
  Handle(Geom_Curve) placed = Handle(Geom_Curve)::DownCast(c->Transformed(loc.Transformation()));
  Handle(Geom_Curve) flipped = placed->Reversed();
  BRepBuilderAPI_MakeEdge mk(flipped, placed->ReversedParameter(last), placed->ReversedParameter(first));
  if (!mk.IsDone()) return w;
  return BRepBuilderAPI_MakeWire(mk.Edge()).Wire();
}

/// The name tag of a profile edge, for a copy of the profile that was moved by `at`.
std::string edgeTagAt(const Profile &p, const TopLoc_Location &at, const TopoDS_Shape &edge) {
  for (const Named &t : p.edgeTags)
    if (t.shape.Moved(at).IsSame(edge)) return t.name;
  return "?";
}

/// The centerline a loft follows: the part of the path between the first and the last section, and the direction square to the
/// path's plane, which keeps the sections from rolling about the path as they go.
struct Spine {
  TopoDS_Wire wire;
  gp_Dir normal;
  bool reversed = false;  // the wire runs from the last section to the first
  /// How the shape is carried along the path. Where the path meets every section at a right angle the shape stays square to
  /// the path all the way, turning with it (a bent duct). Otherwise the sections are parallel and the shape stays parallel to
  /// them, only moving sideways with the path: OCCT's turning sweep through sections that stand at a slant to the path gets
  /// thinner the more they slant and then collapses to nothing, without reporting an error.
  bool turns = true;
  gp_Ax2 fixed;  // the sections' own axes, for the sweep that does not turn
};

/// Where the planar face `f` meets the path: the parameter on `curve` where it crosses the face's plane, the crossing nearest to
/// the face's middle if there are several. A path that stops short of the plane gives its end nearest to the face.
double spineParameter(const BRepAdaptor_CompCurve &curve, const TopoDS_Face &f) {
  BRepAdaptor_Surface surf(f);
  GProp_GProps props;
  BRepGProp::SurfaceProperties(f, props);
  const gp_Pnt middle = props.CentreOfMass();
  const double t0 = curve.FirstParameter(), t1 = curve.LastParameter();
  double best = middle.Distance(curve.Value(t0)) <= middle.Distance(curve.Value(t1)) ? t0 : t1;
  if (surf.GetType() != GeomAbs_Plane) return best;
  const gp_Pln plane = surf.Plane();
  const gp_Dir n = plane.Axis().Direction();
  auto height = [&](double t) { return gp_Vec(plane.Location(), curve.Value(t)).Dot(gp_Vec(n)); };
  const int steps = 512;
  double bestD = -1, prevT = t0, prevH = height(t0);
  for (int i = 1; i <= steps; ++i) {
    const double t = t0 + (t1 - t0) * i / steps, h = height(t);
    if ((prevH <= 0) != (h <= 0) || std::fabs(prevH) < 1e-9 || (i == steps && std::fabs(h) < 1e-9)) {
      double a = prevT, b = t, ha = prevH;
      if (std::fabs(prevH) < 1e-9) b = a;
      else if (std::fabs(h) < 1e-9) a = b;
      for (int k = 0; k < 60 && b - a > 1e-12; ++k) {
        const double m = 0.5 * (a + b), hm = height(m);
        if ((ha <= 0) == (hm <= 0)) a = m, ha = hm;
        else b = m;
      }
      const double root = 0.5 * (a + b), d = middle.Distance(curve.Value(root));
      if (bestD < 0 || d < bestD) bestD = d, best = root;
    }
    prevT = t, prevH = h;
  }
  return best;
}

/// The stretch of `path` from the plane of the first face to the plane of the last, as the spine of a loft.
bool spineBetween(const Path &path, const std::vector<TopoDS_Face> &faces, Spine &out) {
  const TopoDS_Face &first = faces.front(), &last = faces.back();
  if (path.wire.Closed()) {
    setError("a loft's path has to be an open curve that runs from the first profile to the last");
    return false;
  }
  BRepAdaptor_CompCurve curve(path.wire);
  double a = spineParameter(curve, first), b = spineParameter(curve, last);
  out.normal = path.frame.Direction();
  out.reversed = a > b;
  if (out.reversed) std::swap(a, b);
  const char *reach = "the path has to run from the first profile to the last (draw it so that it reaches both profiles' planes)";
  if (b - a < 1e-7 || curve.Value(a).Distance(curve.Value(b)) < 1e-6) {
    setError(reach);
    return false;
  }
  // A path drawn by hand may stop a hair short of a profile's plane; more than that and it is not this loft's path.
  GProp_GProps length;
  BRepGProp::LinearProperties(path.wire, length);
  const double slack = std::max(0.02 * length.Mass(), 1e-6);
  auto gap = [&](const TopoDS_Face &f, double t) {
    BRepAdaptor_Surface surf(f);
    return surf.GetType() == GeomAbs_Plane ? surf.Plane().Distance(curve.Value(t)) : 0.0;
  };
  if (gap(first, out.reversed ? b : a) > slack || gap(last, out.reversed ? a : b) > slack) {
    setError(reach);
    return false;
  }
  bool square = true, parallel = true;
  gp_Dir firstNormal;
  for (size_t k = 0; k < faces.size(); ++k) {
    BRepAdaptor_Surface surf(faces[k]);
    if (surf.GetType() != GeomAbs_Plane) continue;
    const gp_Ax3 axes = surf.Plane().Position();
    const gp_Dir n = axes.Direction();
    if (k == 0) firstNormal = n, out.fixed = gp_Ax2(axes.Location(), n, axes.XDirection());
    else if (!n.IsParallel(firstNormal, 1e-6)) parallel = false;
    gp_Pnt at;
    gp_Vec tangent;
    curve.D1(spineParameter(curve, faces[k]), at, tangent);
    if (tangent.Magnitude() < 1e-12 || !gp_Dir(tangent).IsParallel(n, 3 * M_PI / 180)) square = false;
  }
  if (!square && !parallel) {
    setError("the path has to meet every profile at a right angle, unless the profiles are all parallel to each other");
    return false;
  }
  out.turns = square;
  TopoDS_Edge edgeA, edgeB;
  double onA, onB;
  curve.Edge(a, edgeA, onA);
  curve.Edge(b, edgeB, onB);
  BRepBuilderAPI_MakeWire wire;
  bool inside = false, done = false;
  for (BRepTools_WireExplorer ex(path.wire); ex.More() && !done; ex.Next()) {
    const TopoDS_Edge e = ex.Current();
    const bool isA = e.IsSame(edgeA), isB = e.IsSame(edgeB);
    if (!inside && !isA) continue;
    BRepAdaptor_Curve c(e);
    double lo = c.FirstParameter(), hi = c.LastParameter();
    const bool flipped = e.Orientation() == TopAbs_REVERSED;  // the wire runs through this edge from its end to its start
    if (isA) (flipped ? hi : lo) = onA;
    if (isB) (flipped ? lo : hi) = onB;
    inside = true;
    done = isB;
    if (hi - lo < 1e-9) continue;
    TopLoc_Location loc;
    double f, l;
    Handle(Geom_Curve) g = BRep_Tool::Curve(e, loc, f, l);
    if (g.IsNull()) continue;
    Handle(Geom_Curve) placed = Handle(Geom_Curve)::DownCast(g->Transformed(loc.Transformation()));
    BRepBuilderAPI_MakeEdge mk(placed, lo, hi);
    if (!mk.IsDone()) continue;
    wire.Add(TopoDS::Edge(mk.Edge().Oriented(e.Orientation())));
  }
  if (!wire.IsDone()) {
    setError("the path could not be followed between the profiles");
    return false;
  }
  out.wire = wire.Wire();
  return true;
}

/// One solid through closed wires, in order: a loft, or with a spine a sweep along it that takes the shape of each wire where
/// the wire stands.
struct Blend {
  TopoDS_Shape shape, first, last;
  /// The side face that grew from an edge of the first wire (null when it can't be told).
  std::function<TopoDS_Shape(const TopoDS_Shape &)> faceOf;
};

bool blendWires(const std::vector<TopoDS_Wire> &wires, bool ruled, bool sameWires, const Spine *spine, const char *failure,
                Blend &out) {
  if (!spine) {
    auto loft = std::make_shared<BRepOffsetAPI_ThruSections>(true, ruled);
    // Sections that are exact copies of one wire (a twist sweep) already match edge for edge from the same start. The loft's own
    // search for how the corners of one section map to the next's guesses wrong once the sections have turned far from each
    // other, and then fails or twists the solid inside out; with the check off the copies are used as they are.
    if (sameWires) loft->CheckCompatibility(false);
    for (const TopoDS_Wire &w : wires) loft->AddWire(w);
    loft->Build();
    if (!loft->IsDone()) {
      setError(failure);
      return false;
    }
    out.shape = loft->Shape();
    out.first = loft->FirstShape();
    out.last = loft->LastShape();
    out.faceOf = [loft](const TopoDS_Shape &edge) { return loft->GeneratedFace(edge); };
    return true;
  }
  auto pipe = std::make_shared<BRepOffsetAPI_MakePipeShell>(spine->wire);
  if (spine->turns) pipe->SetMode(spine->normal);
  else pipe->SetMode(spine->fixed);
  for (const TopoDS_Wire &w : wires) pipe->Add(w, false, false);  // each section stays where it was drawn
  if (!pipe->IsReady()) {
    setError(failure);
    return false;
  }
  pipe->Build();
  if (!pipe->IsDone() || !pipe->MakeSolid()) {
    setError(failure);
    return false;
  }
  out.shape = pipe->Shape();
  {
    // Depending on which way a section runs around against the spine, the solid can come out inside out (all of space but
    // the loft); cutting with that removes everything.
    GProp_GProps props;
    BRepGProp::VolumeProperties(out.shape, props);
    if (props.Mass() < 0) out.shape.Reverse();
  }
  out.first = spine->reversed ? pipe->LastShape() : pipe->FirstShape();
  out.last = spine->reversed ? pipe->FirstShape() : pipe->LastShape();
  const TopoDS_Shape shape = out.shape, first = out.first, last = out.last;
  out.faceOf = [pipe, shape, first, last](const TopoDS_Shape &edge) -> TopoDS_Shape {
    for (const TopoDS_Shape &g : pipe->Generated(edge))
      if (g.ShapeType() == TopAbs_FACE) return g;
    // No history for this edge (the sections were re-cut to match each other): the side face that touches the edge's middle.
    BRepAdaptor_Curve c(TopoDS::Edge(edge));
    const TopoDS_Vertex mid = BRepBuilderAPI_MakeVertex(c.Value(0.5 * (c.FirstParameter() + c.LastParameter()))).Vertex();
    for (TopExp_Explorer fx(shape, TopAbs_FACE); fx.More(); fx.Next()) {
      const TopoDS_Shape &f = fx.Current();
      if (f.IsSame(first) || f.IsSame(last)) continue;
      BRepExtrema_DistShapeShape d(mid, f);
      if (d.IsDone() && d.Value() < 1e-6) return f;
    }
    return TopoDS_Shape();
  };
  return true;
}

/// Lofts through the outer boundaries of `faces` (one per section, in order), cutting out the holes they all share. Side faces
/// are named after the edges of `tagProfile`, which `faces[0]` is a copy of moved by `tagAt`. With a `spine` the loft follows it.
bool loftFaces(const std::vector<TopoDS_Face> &faces, const Profile &tagProfile, const TopLoc_Location &tagAt, bool ruled,
               const std::string &feat, TopoDS_Shape &outShape, std::vector<Named> &outNames, bool sameWires = false,
               const Spine *spine = nullptr) {
  std::vector<TopoDS_Wire> wires;
  for (const TopoDS_Face &f : faces) wires.push_back(BRepTools::OuterWire(f));
  Blend loft;
  if (!blendWires(wires, ruled, sameWires, spine,
                  spine ? "loft failed (does the path bend too tightly for the profiles, or do the profiles cross?)"
                        : "loft failed (are the profiles far enough apart, and not crossing?)",
                  loft))
    return false;
  if (spine) {
    // A sweep that folded up on itself still counts as done and valid: it shows as next to no volume for its size.
    GProp_GProps volume, length;
    BRepGProp::VolumeProperties(loft.shape, volume);
    BRepGProp::LinearProperties(spine->wire, length);
    double smallest = -1;
    for (const TopoDS_Face &f : faces) {
      GProp_GProps area;
      BRepGProp::SurfaceProperties(BRepBuilderAPI_MakeFace(BRepTools::OuterWire(f)).Face(), area);
      if (smallest < 0 || std::fabs(area.Mass()) < smallest) smallest = std::fabs(area.Mass());
    }
    if (volume.Mass() < 0.05 * smallest * length.Mass()) {
      setError("the loft folds up along this path (does the path bend too tightly for the profiles, or run almost along one?)");
      return false;
    }
  }
  std::vector<Named> names{{loft.first, feat + ".start"}, {loft.last, feat + ".end"}};
  for (TopExp_Explorer ex(wires[0], TopAbs_EDGE); ex.More(); ex.Next()) {
    TopoDS_Shape g = loft.faceOf(ex.Current());
    if (!g.IsNull()) names.push_back({g, feat + ".side." + edgeTagAt(tagProfile, tagAt, ex.Current())});
  }

  // Holes in the profiles (a ring, say) loft too, and are cut out of the outer loft. Every profile
  // must have the same number of holes; each hole is matched to the nearest one in the previous profile.
  std::vector<std::vector<TopoDS_Wire>> holes(faces.size());
  for (size_t k = 0; k < faces.size(); ++k)
    for (TopExp_Explorer wx(faces[k], TopAbs_WIRE); wx.More(); wx.Next())
      if (!wx.Current().IsSame(wires[k])) holes[k].push_back(TopoDS::Wire(wx.Current()));
  if (std::all_of(holes.begin(), holes.end(), [](auto &h) { return h.empty(); })) {
    outShape = loft.shape;
    outNames = names;
    return true;
  }
  for (auto &h : holes)
    if (h.size() != holes[0].size()) {
      setError("every profile in a loft needs the same number of holes");
      return false;
    }
  auto centre = [](const TopoDS_Wire &w) {
    GProp_GProps g;
    BRepGProp::LinearProperties(w, g);
    return g.CentreOfMass();
  };
  std::vector<std::vector<TopoDS_Wire>> chains(holes[0].size());  // chains[hole][profile]
  for (size_t h = 0; h < holes[0].size(); ++h) chains[h].push_back(holes[0][h]);
  for (size_t k = 1; k < faces.size(); ++k) {
    std::vector<bool> used(holes[k].size(), false);
    for (auto &chain : chains) {
      const gp_Pnt from = centre(chain.back());
      int best = -1;
      double bestD = 0;
      for (size_t j = 0; j < holes[k].size(); ++j) {
        const double d = from.Distance(centre(holes[k][j]));
        if (!used[j] && (best < 0 || d < bestD)) best = (int)j, bestD = d;
      }
      used[best] = true;
      chain.push_back(holes[k][best]);
    }
  }
  TopoDS_Shape result = loft.shape;
  std::vector<Named> boreNames;
  for (size_t h = 0; h < chains.size(); ++h) {
    std::vector<TopoDS_Wire> boreWires;
    TopoDS_Wire firstWire;
    TopoDS_Edge firstEdge;
    for (size_t k = 0; k < chains[h].size(); ++k) {
      TopoDS_Edge own;
      TopoDS_Wire w = forwardWire(chains[h][k], own);
      if (k == 0) firstWire = w, firstEdge = own;
      boreWires.push_back(w);
    }
    Blend bore;
    if (!blendWires(boreWires, ruled, sameWires, spine, "could not loft the profiles' holes", bore)) return false;
    for (TopExp_Explorer ex(firstWire, TopAbs_EDGE); ex.More(); ex.Next()) {
      TopoDS_Shape g = bore.faceOf(ex.Current());
      // the rebuilt wire has one edge; its tag is the profile edge's
      const TopoDS_Shape &tagged = firstWire.IsSame(chains[h][0]) ? ex.Current() : firstEdge;
      if (!g.IsNull()) boreNames.push_back({g, feat + ".hole." + edgeTagAt(tagProfile, tagAt, tagged)});
    }
    BRepAlgoAPI_Cut cut(result, bore.shape);
    if (!cut.IsDone() || cut.HasErrors()) {
      setError("could not hollow the loft");
      return false;
    }
    std::vector<Named> carriedOuter, carriedBore;
    carry(cut, names, carriedOuter);
    carry(cut, boreNames, carriedBore);
    names = std::move(carriedOuter);
    names.insert(names.end(), carriedBore.begin(), carriedBore.end());
    boreNames.clear();
    result = cut.Shape();
  }
  outShape = result;
  outNames = names;
  return true;
}


/// A loft through `profiles`, in order; with a path it follows the path between the first profile and the last.
SKHandle loftProfiles(const SKHandle *profiles, int count, bool ruled, const Path *path, const char *featureId) {
  const std::string feat = featureOrDefault(featureId, "loft");
  std::vector<std::shared_ptr<Object>> keep;
  std::vector<Profile *> ps;
  if (!profilesOf(profiles, count, keep, ps, "loft")) return 0;
  if (count < 2) {
    setError("a loft needs at least two profiles");
    return 0;
  }
  std::vector<TopoDS_Face> faces;
  for (Profile *p : ps) faces.push_back(p->face);
  Spine spine;
  if (path && !spineBetween(*path, faces, spine)) return 0;
  TopoDS_Shape shape;
  std::vector<Named> names;
  if (!loftFaces(faces, *ps[0], TopLoc_Location(), ruled, feat, shape, names, false, path ? &spine : nullptr)) return 0;
  return storeChecked(shape, names, feat,
                      path ? "the loft along the path is not a valid solid (does the path bend too tightly for the profiles?)"
                           : "loft produced an invalid solid");
}

SKHandle sk_loft(const SKHandle *profiles, int count, bool ruled, const char *featureId) {
  SK_TRY
  return loftProfiles(profiles, count, ruled, nullptr, featureId);
  SK_CATCH(0)
}

SKHandle sk_loft_along(const SKHandle *profiles, int count, SKHandle path, const char *featureId) {
  SK_TRY
  Path *pa;
  auto keepPath = lookup(path, pa);
  if (!pa) return 0;
  return loftProfiles(profiles, count, false, pa, featureId);
  SK_CATCH(0)
}

SKHandle sk_twist_sweep(const SKHandle *profiles, int count, double dx, double dy, double dz, double distance, bool hasPivot,
                        double px, double py, double pz, double startAngle, double endAngle, double power, double shiftX,
                        double shiftY, double shiftZ, int sections, bool ruled, const char *featureId) {
  SK_TRY
  const std::string feat = featureOrDefault(featureId, "twist");
  if (count < 1) {
    setError("a twist sweep needs at least one profile");
    return 0;
  }
  if (std::fabs(distance) <= Precision::Confusion()) {
    setError("the twist sweep length is zero");
    return 0;
  }
  if (sections < 2 || sections > 200) {
    setError("a twist sweep needs between 2 and 200 sections");
    return 0;
  }
  if (!(power > 0) || !std::isfinite(power)) {
    setError("the twist curve has to be a positive number (1 = even)");
    return 0;
  }
  const gp_Dir dir(dx, dy, dz);
  const gp_Vec shift(shiftX, shiftY, shiftZ);
  std::vector<TopoDS_Shape> solids;
  std::vector<Named> names;
  for (int k = 0; k < count; ++k) {
    Profile *p;
    auto keep = lookup(profiles[k], p);
    if (!p) return 0;
    // The profile turns about the line through the pivot along the sweep direction: the point given, else the profile's own middle.
    gp_Pnt pivot(px, py, pz);
    if (!hasPivot) {
      GProp_GProps props;
      BRepGProp::SurfaceProperties(p->face, props);
      pivot = props.CentreOfMass();
    }
    std::vector<TopoDS_Face> faces;
    TopLoc_Location first;
    for (int i = 0; i <= sections; ++i) {
      const double t = double(i) / sections;
      const double angle = startAngle + (endAngle - startAngle) * std::pow(t, power);
      gp_Trsf turn;
      turn.SetRotation(gp_Ax1(pivot, dir), angle);
      gp_Trsf move;
      move.SetTranslation(gp_Vec(dir) * (distance * t) + shift * t);
      const TopLoc_Location at(move.Multiplied(turn));  // turn first, then move
      faces.push_back(TopoDS::Face(p->face.Moved(at)));
      if (i == 0) first = at;
    }
    TopoDS_Shape solid;
    std::vector<Named> own;
    if (!loftFaces(faces, *p, first, ruled, feat, solid, own, true)) return 0;
    solids.push_back(solid);
    names.insert(names.end(), own.begin(), own.end());
  }
  TopoDS_Shape result;
  if (!fuseAll(solids, names, result)) return 0;
  return storeChecked(result, names, feat, "the twist sweep produced an invalid solid (does the profile turn through itself?)");
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
  // The rib is the part of the sketch plane that the path closes off against the body, thickened across the plane.
  // (BRepFeat_MakeLinearForm builds the same thing, but only for one handedness of path against plane: the other way
  // it throws, fills towards infinity or never returns, so it is not used.) The path's two ends are extended along
  // their tangents far past the body; the plane outside the body is cut by the path and the extensions; the pieces
  // that stay within the room of the body and the path and touch the path are the rib's profile.
  Bnd_Box room;
  BRepBndLib::Add(b->shape, room);
  BRepBndLib::Add(pa->wire, room);
  const double reach = 4 * std::sqrt(room.SquareExtent()) + 1;
  room.Enlarge(1e-3 + thickness);

  BRepAdaptor_CompCurve curve(pa->wire);
  gp_Pnt first, last;
  gp_Vec dFirst, dLast;
  curve.D1(curve.FirstParameter(), first, dFirst);
  curve.D1(curve.LastParameter(), last, dLast);
  if (dFirst.Magnitude() < Precision::Confusion() || dLast.Magnitude() < Precision::Confusion()) {
    setError("the rib's path has no direction at one end");
    return 0;
  }
  dFirst.Normalize();
  dLast.Normalize();

  ShapeList tools;
  for (TopExp_Explorer ex(pa->wire, TopAbs_EDGE); ex.More(); ex.Next()) tools.Append(ex.Current());
  const TopoDS_Edge beyondFirst = BRepBuilderAPI_MakeEdge(first, first.Translated(dFirst.Reversed() * reach)).Edge();
  const TopoDS_Edge beyondLast = BRepBuilderAPI_MakeEdge(last, last.Translated(dLast * reach)).Edge();
  tools.Append(beyondFirst);
  tools.Append(beyondLast);

  // Each end, carried on past itself, has to run into the body. Say which one does not, where it is in the sketch
  // and how far it misses, because the fix is to move that end.
  auto sketchPoint = [&](const gp_Pnt &p) {
    const gp_Vec d(pa->frame.Location(), p);
    char text[64];
    std::snprintf(text, sizeof text, "(%.1f, %.1f)", d.Dot(gp_Vec(pa->frame.XDirection())), d.Dot(gp_Vec(pa->frame.YDirection())));
    return std::string(text);
  };
  const std::pair<const char *, std::pair<gp_Pnt, TopoDS_Edge>> ends[] = {{"first", {first, beyondFirst}}, {"last", {last, beyondLast}}};
  for (const auto &[which, end] : ends) {
    BRepExtrema_DistShapeShape reach_(end.second, b->shape);
    if (!reach_.IsDone()) continue;
    char text[300];
    if (reach_.Value() > 1e-4) {
      std::snprintf(text, sizeof text,
                    "the %s end of the line, at %s mm in its sketch, does not reach the body: carried on past the end, the line misses it by %.2f mm "
                    "(move that end, or change the line's angle, so that it runs into the body)",
                    which, sketchPoint(end.first).c_str(), reach_.Value());
      setError(text);
      return 0;
    }
    // It meets the body: does it run into the material, or only brush an edge or a corner on its way past?
    double inside = 1;
    try {
      BRepAlgoAPI_Common within(end.second, b->shape);
      if (within.IsDone() && !within.HasErrors()) {
        GProp_GProps g;
        BRepGProp::LinearProperties(within.Shape(), g);
        inside = g.Mass();
      }
    } catch (const Standard_Failure &) {
    }
    if (inside <= 1e-4) {
      std::snprintf(text, sizeof text,
                    "the %s end of the line, at %s mm in its sketch, only touches the body at an edge or a corner: carried on past the end, the "
                    "line goes by without running into it (end the line a little way up a face instead of on its edge, or change "
                    "its angle)",
                    which, sketchPoint(end.first).c_str());
      setError(text);
      return 0;
    }
  }

  const gp_Dir normal = pa->frame.Direction();
  gp_Pnt centre(0.5 * (room.CornerMin().X() + room.CornerMax().X()), 0.5 * (room.CornerMin().Y() + room.CornerMax().Y()),
                0.5 * (room.CornerMin().Z() + room.CornerMax().Z()));
  centre.Translate(gp_Vec(normal).Reversed() * gp_Vec(pa->frame.Location(), centre).Dot(gp_Vec(normal)));  // onto the plane
  TopoDS_Face base = BRepBuilderAPI_MakeFace(gp_Pln(gp_Ax3(centre, normal, pa->frame.XDirection())), -reach, reach, -reach, reach).Face();

  BRepAlgoAPI_Cut outside(base, b->shape);
  if (!outside.IsDone() || outside.HasErrors()) {
    setError("could not find the space the rib fills");
    return 0;
  }
  BRepAlgoAPI_Splitter split;
  ShapeList args;
  args.Append(outside.Shape());
  split.SetArguments(args);
  split.SetTools(tools);
  split.SetFuzzyValue(1e-6);
  split.Build();
  if (!split.IsDone() || split.HasErrors()) {
    setError("could not find the space the rib fills");
    return 0;
  }

  const gp_Vec half = gp_Vec(normal) * (thickness / 2);
  gp_Trsf back;
  back.SetTranslation(half.Reversed());
  TopoDS_Shape rib;
  for (TopExp_Explorer fx(split.Shape(), TopAbs_FACE); fx.More(); fx.Next()) {
    const TopoDS_Shape &piece = fx.Current();
    Bnd_Box pb;
    BRepBndLib::Add(piece, pb);
    if (pb.IsVoid() || room.IsOut(pb.CornerMin()) || room.IsOut(pb.CornerMax())) continue;  // runs off to the edge: open air
    BRepExtrema_DistShapeShape touch(piece, pa->wire);
    if (!touch.IsDone() || touch.Value() > 1e-3) continue;  // not bounded by the path
    TopoDS_Shape moved = BRepBuilderAPI_Transform(piece, back, true).Shape();
    TopoDS_Shape slab = BRepPrimAPI_MakePrism(moved, gp_Vec(normal) * thickness).Shape();
    if (rib.IsNull()) {
      rib = slab;
    } else {
      BRepAlgoAPI_Fuse more(rib, slab);
      if (more.IsDone() && !more.HasErrors()) rib = more.Shape();
    }
  }
  if (rib.IsNull()) {
    setError("both ends of the line run into the body, but the line closes off no space against it "
             "(a rib is the space between the line and a corner of the body; the line has to cross that corner)");
    return 0;
  }
  std::vector<Named> names = namedFaces(*b);
  TopoDS_Shape fused = b->shape;
  if (!namedBoolean(fused, names, rib, feat + ".rib", SK_FUSE)) {
    setError("the rib could not be joined to the body");
    return 0;
  }
  auto volumeOf = [](const TopoDS_Shape &sh) {
    GProp_GProps g;
    BRepGProp::VolumeProperties(sh, g);
    return g.Mass();
  };
  const double bodyVolume = volumeOf(b->shape);
  // A line that only clips a corner of the body (a rib sketched across another body's thin wall) closes off a sliver;
  // that is not what was drawn, and the rib would be silently built there, so a sliver is an error.
  const double pathLength = GCPnts_AbscissaPoint::Length(curve);
  const double added = volumeOf(fused) - bodyVolume;
  if (added <= std::max(1e-6 * bodyVolume, 1e-3 * thickness * pathLength * pathLength)) {
    char text[220];
    std::snprintf(text, sizeof text,
                  "the line closes off only %.2f mm3 against this body, too little to be a rib: it only clips the body "
                  "(a line %.0f mm long needs a corner to run across)", std::max(added, 0.0), pathLength);
    setError(text);
    return 0;
  }
  TopoDS_Shape result = unify(fused, names);
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
  return sk_thread_many(body, 1, &faceName, &majorDiameter, &pitch, length, flipped, leftHanded, featureId);
}

SKHandle sk_thread_many(SKHandle body, int count, const char *const *faceNames, const double *majorDiameters,
                        const double *pitches, double length, bool flipped, bool leftHanded, const char *featureId) {
  SK_TRY
  const std::string feat = featureOrDefault(featureId, "thread");
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return 0;
  if (count < 1) {
    setError("no round face to thread");
    return 0;
  }
  std::vector<ThreadJob> jobs(count);
  for (int i = 0; i < count; ++i) {
    // The first face names its new faces after the feature, the rest "<id>.2", "<id>.3"...
    if (!planThread(*b, faceNames[i], majorDiameters[i], pitches[i], length, flipped, leftHanded,
                    i == 0 ? feat : feat + "." + std::to_string(i + 1), jobs[i]))
      return 0;
  }
  if (!threadsApart(jobs)) {
    setError("the threads are too close together to be cut in one go");
    return 0;
  }
  return threadsInto(*b, jobs);
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

SKHandle sk_draft(SKHandle body, const char *const *faceNames, int count, const char *fixedFace, double angle,
                  const char *featureId) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return 0;
  if (count <= 0) {
    setError("no faces to draft");
    return 0;
  }
  auto fixedIt = b->faceIndex.find(fixedFace);
  if (fixedIt == b->faceIndex.end()) {
    setError(std::string("face not found: ") + fixedFace);
    return 0;
  }
  const TopoDS_Face &fixed = TopoDS::Face(b->faces(fixedIt->second + 1));
  BRepAdaptor_Surface fixedSurface(fixed);
  if (fixedSurface.GetType() != GeomAbs_Plane) {
    setError("the face that stays put must be flat");
    return 0;
  }
  // The pull direction points from the fixed face into the body; a draft angle that is positive takes matter away on
  // the side it points to, so the faces lean towards each other as they go away from the fixed face.
  const gp_Dir pull = planeNormal(fixed, fixedSurface.Plane()).Reversed();
  const gp_Pln neutral(fixedSurface.Plane().Location(), pull);

  BRepOffsetAPI_DraftAngle draft(b->shape);
  for (int k = 0; k < count; ++k) {
    auto it = b->faceIndex.find(faceNames[k]);
    if (it == b->faceIndex.end()) {
      setError(std::string("face not found: ") + faceNames[k]);
      return 0;
    }
    draft.Add(TopoDS::Face(b->faces(it->second + 1)), pull, angle, neutral);
    if (!draft.AddDone()) {
      setError("a face can't be drafted that far, or at all (it must be flat or round, and not square to the pull)");
      return 0;
    }
  }
  draft.Build();
  if (!draft.IsDone()) {
    setError("this draft can't be built (the faces would run into each other or into their neighbours)");
    return 0;
  }
  // A draft reports what became of a face through ModifiedShape (the same face when it was left alone), not Modified.
  std::vector<Named> names;
  for (const Named &n : namedFaces(*b)) names.push_back({draft.ModifiedShape(n.shape), n.name});
  Body out = makeBody(draft.Shape(), names, featureOrDefault(featureId, "draft") + ".draft");
  if (!BRepCheck_Analyzer(out.shape).IsValid()) {
    setError("this draft can't be built (the faces would run into each other or into their neighbours)");
    return 0;
  }
  return store(std::move(out));
  SK_CATCH(0)
}

// ------------------------------------------------- projection onto a body ---
namespace {

/// A face's outward unit normal near `near`, and the point on the face's surface it was taken at.
bool faceNormalNear(const TopoDS_Face &f, const gp_Pnt &near, gp_Pnt &on, gp_Dir &normal) {
  Handle(Geom_Surface) surface = BRep_Tool::Surface(f);
  if (surface.IsNull()) return false;
  GeomAPI_ProjectPointOnSurf proj(near, surface);
  if (proj.NbPoints() < 1) return false;
  double u = 0, v = 0;
  proj.LowerDistanceParameters(u, v);
  BRepLProp_SLProps props(BRepAdaptor_Surface(f), u, v, 1, 1e-6);
  if (!props.IsNormalDefined()) return false;
  normal = props.Normal();
  if (f.Orientation() == TopAbs_REVERSED) normal.Reverse();
  on = props.Value();
  return true;
}

/// The solid between a patch of a body's surface pushed `from` and pushed `to` along its outward normal
/// (from < to; either may be negative, which is into the body).
TopoDS_Shape thickenPatch(const TopoDS_Face &patch, double from, double to) {
  TopoDS_Shape base = patch;
  if (std::fabs(from) > 1e-9) {
    BRepOffsetAPI_MakeOffsetShape moved;
    moved.PerformByJoin(patch, from, 1e-5, BRepOffset_Skin, false, false, GeomAbs_Intersection);
    if (!moved.IsDone()) return TopoDS_Shape();
    base = moved.Shape();
  }
  BRepOffset_MakeOffset thick;
  thick.Initialize(base, to - from, 1e-5, BRepOffset_Skin, false, false, GeomAbs_Intersection, true, false);
  thick.MakeOffsetShape();
  if (!thick.IsDone()) return TopoDS_Shape();
  return thick.Shape();
}

/// Whether `p` lies inside `solid`.
bool solidHolds(const TopoDS_Shape &solid, const gp_Pnt &p) {
  BRepClass3d_SolidClassifier c(solid, p, 1e-7);
  return c.State() == TopAbs_IN;
}


/// The profiles laid onto a round (cylindrical) face the way a label is wrapped round a can: unrolled, so that a
/// length in the sketch is the same length along the surface, however far the surface has turned away. The sketch
/// plane touches the cylinder where the line through `centre` along `dir` meets the side that faces the sketch; there
/// the sketch and the surface agree, and everything else is measured out from that point across and along the face.
/// `wrapped` gets one face per profile, lying on the cylinder (not yet cut down to the face). False when the face isn't
/// a cylinder, the sketch isn't parallel to its axis, or the line misses it.
bool wrapOntoCylinder(const TopoDS_Face &face, const std::vector<Profile *> &ps, const gp_Pnt &centre, const gp_Dir &dir,
                      TopoDS_Compound &wrapped) {
  BRepAdaptor_Surface adaptor(face);
  if (adaptor.GetType() != GeomAbs_Cylinder) return false;
  const gp_Cylinder cyl = adaptor.Cylinder();
  const double radius = cyl.Radius();
  const gp_Dir axis = cyl.Axis().Direction();
  if (radius < 1e-6 || std::fabs(axis.Dot(dir)) > 0.02) return false;

  // Where the line through the middle of the profiles meets the cylinder, on the side that faces the sketch.
  const gp_Vec q(cyl.Location(), centre);
  const gp_Vec qPerp = q - gp_Vec(axis) * q.Dot(gp_Vec(axis));
  const gp_Vec dPerp = gp_Vec(dir) - gp_Vec(axis) * gp_Vec(dir).Dot(gp_Vec(axis));
  const double a = dPerp.SquareMagnitude();
  if (a < 1e-12) return false;
  const double b = qPerp.Dot(dPerp) / a, c = (qPerp.SquareMagnitude() - radius * radius) / a;
  const double disc = b * b - c;
  if (disc < 0) return false;
  double hit = 0;
  bool found = false;
  for (double t : {-b - std::sqrt(disc), -b + std::sqrt(disc)}) {
    // Which way the body's surface faces there is the face's own say (a cylinder can be built either way round).
    gp_Pnt on;
    gp_Dir normal;
    if (!faceNormalNear(face, centre.Translated(gp_Vec(dir) * t), on, normal)) continue;
    if (normal.Dot(dir) < 0) {
      hit = t;
      found = true;
      break;
    }
  }
  if (!found) return false;
  const gp_Pnt touch = centre.Translated(gp_Vec(dir) * hit);

  // The same cylinder with its seam on the far side from the touching point, so the wrapped profiles never straddle it.
  const gp_Vec fromAxis = gp_Vec(cyl.Location(), touch) - gp_Vec(axis) * gp_Vec(cyl.Location(), touch).Dot(gp_Vec(axis));
  if (fromAxis.Magnitude() < 1e-9) return false;
  const gp_Cylinder rebased(gp_Ax3(cyl.Location(), axis, gp_Dir(fromAxis.Reversed())), radius);
  double u0 = 0, v0 = 0;
  ElSLib::Parameters(rebased, touch, u0, v0);
  gp_Pnt onSurface;
  gp_Vec du, dv;
  ElSLib::D1(u0, v0, rebased, onSurface, du, dv);

  // The sketch's own directions at the touching point: along the axis, and across it.
  const gp_Vec along = (gp_Vec(axis) - gp_Vec(dir) * axis.Dot(dir)).Normalized();
  const gp_Vec across = gp_Vec(dir).Crossed(along).Normalized();
  const double signU = du.Dot(across) >= 0 ? 1.0 : -1.0;
  const double signV = dv.Dot(along) >= 0 ? 1.0 : -1.0;
  auto toSurface = [&](const gp_Pnt &p) {
    const gp_Vec d(centre, p);
    return gp_Pnt2d(u0 + signU * d.Dot(across) / radius, v0 + signV * d.Dot(along));
  };

  Handle(Geom_Surface) surface = new Geom_CylindricalSurface(rebased);
  BRep_Builder builder;
  builder.MakeCompound(wrapped);
  for (Profile *p : ps) {
    BRepBuilderAPI_MakeFace made;
    bool firstWire = true;
    const TopoDS_Wire outer = BRepTools::OuterWire(p->face);
    std::vector<TopoDS_Wire> wires{outer};
    for (TopExp_Explorer ex(p->face, TopAbs_WIRE); ex.More(); ex.Next()) {
      const TopoDS_Wire w = TopoDS::Wire(ex.Current());
      if (!w.IsSame(outer)) wires.push_back(w);
    }
    for (const TopoDS_Wire &wire : wires) {
      // The wire's edges, in order, as lists of points on the unrolled surface; each starts where the last ended.
      std::vector<std::vector<gp_Pnt2d>> runs;
      std::vector<bool> straight;
      for (BRepTools_WireExplorer we(wire); we.More(); we.Next()) {
        const TopoDS_Edge edge = we.Current();
        BRepAdaptor_Curve curve(edge);
        const bool reversed = edge.Orientation() == TopAbs_REVERSED;
        const double lo = curve.FirstParameter(), hi = curve.LastParameter();
        const bool line = curve.GetType() == GeomAbs_Line;
        const double length = GCPnts_AbscissaPoint::Length(curve);
        const int n = line ? 1 : std::max(8, std::min(240, static_cast<int>(length / 0.25) + 8));
        std::vector<gp_Pnt2d> run;
        for (int k = 0; k <= n; ++k) {
          const double f = static_cast<double>(k) / n;
          run.push_back(toSurface(curve.Value(reversed ? hi + (lo - hi) * f : lo + (hi - lo) * f)));
        }
        runs.push_back(std::move(run));
        straight.push_back(line);
      }
      if (runs.empty()) return false;
      for (size_t k = 0; k < runs.size(); ++k) {
        if (k > 0) runs[k].front() = runs[k - 1].back();
      }
      runs.back().back() = runs.front().front();

      BRepBuilderAPI_MakeWire mw;
      for (size_t k = 0; k < runs.size(); ++k) {
        const std::vector<gp_Pnt2d> &run = runs[k];
        if (run.front().Distance(run.back()) < 1e-9 && run.size() < 4) continue;
        Handle(Geom2d_Curve) curve2d;
        if (straight[k]) {
          GCE2d_MakeSegment segment(run.front(), run.back());
          if (!segment.IsDone()) return false;
          curve2d = segment.Value();
        } else {
          Handle(NCollection_HArray1<gp_Pnt2d>) pts = new NCollection_HArray1<gp_Pnt2d>(1, static_cast<int>(run.size()));
          for (size_t m = 0; m < run.size(); ++m) pts->SetValue(static_cast<int>(m) + 1, run[m]);
          Geom2dAPI_Interpolate interpolate(pts, false, 1e-7);
          interpolate.Perform();
          if (!interpolate.IsDone()) return false;
          curve2d = interpolate.Curve();
        }
        BRepBuilderAPI_MakeEdge me(curve2d, surface);
        if (!me.IsDone()) return false;
        mw.Add(me.Edge());
        if (!mw.IsDone()) return false;
      }
      if (!mw.IsDone()) return false;
      if (firstWire) {
        made = BRepBuilderAPI_MakeFace(surface, mw.Wire(), true);
        firstWire = false;
      } else {
        made.Add(mw.Wire());
      }
    }
    if (!made.IsDone()) return false;
    TopoDS_Face wrappedFace = made.Face();
    BRepLib::BuildCurves3d(wrappedFace, 1e-6);
    ShapeFix_Face fix(wrappedFace);
    fix.Perform();
    fix.FixOrientation();
    builder.Add(wrapped, fix.Face());
  }
  return true;
}

}  // namespace

SKHandle sk_project_relief(SKHandle body, const char *const *faceNames, int faceCount, const SKHandle *profiles, int count,
                           double dx, double dy, double dz, double height, bool wrap, const char *featureId, double handle[6]) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return 0;
  if (std::fabs(height) <= 1e-6) {
    setError("the height must be more than zero");
    return 0;
  }
  const std::string feat = featureOrDefault(featureId, "project");
  std::vector<std::shared_ptr<Object>> keepProfiles;
  std::vector<Profile *> ps;
  if (!profilesOf(profiles, count, keepProfiles, ps, "project")) return 0;
  gp_Dir dir(dx, dy, dz);

  // The faces to project onto: those named, or every face of the body.
  std::vector<TopoDS_Face> targets;
  if (faceCount > 0) {
    for (int k = 0; k < faceCount; ++k) {
      auto it = b->faceIndex.find(faceNames[k]);
      if (it == b->faceIndex.end()) {
        setError(std::string("face not found: ") + faceNames[k]);
        return 0;
      }
      targets.push_back(TopoDS::Face(b->faces(it->second + 1)));
    }
  } else {
    for (int i = 1; i <= b->faces.Extent(); ++i) targets.push_back(TopoDS::Face(b->faces(i)));
  }

  // Each profile, drawn out as a prism that runs both ways past the whole body along the direction.
  Bnd_Box box;
  BRepBndLib::Add(b->shape, box);
  if (box.IsVoid()) {
    setError("the body is empty");
    return 0;
  }
  const gp_Pnt lo = box.CornerMin(), hi = box.CornerMax();
  const double diagonal = lo.Distance(hi);
  TopoDS_Compound prisms;
  BRep_Builder builder;
  builder.MakeCompound(prisms);
  // Profiles that touch (the pieces a drawing is cut into by its own lines) are joined into one outline first: prisms
  // standing side by side on shared walls, or overlapping, make the boolean below fail.
  std::vector<TopoDS_Face> shapes;
  for (Profile *p : ps) shapes.push_back(TopoDS::Face(p->face));
  if (ps.size() > 1) {
    try {
      ShapeList objects, tools;
      for (size_t k = 0; k < ps.size(); ++k) (k == 0 ? objects : tools).Append(ps[k]->face);
      BRepAlgoAPI_Fuse fuse;
      fuse.SetArguments(objects);
      fuse.SetTools(tools);
      fuse.Build();
      if (fuse.IsDone() && !fuse.HasErrors()) {
        ShapeUpgrade_UnifySameDomain unify(fuse.Shape(), true, true, true);
        unify.Build();
        std::vector<TopoDS_Face> merged;
        for (TopExp_Explorer ex(unify.Shape(), TopAbs_FACE); ex.More(); ex.Next()) {
          GProp_GProps props;
          BRepGProp::SurfaceProperties(ex.Current(), props);
          if (props.Mass() > 1e-9) merged.push_back(TopoDS::Face(ex.Current()));
        }
        if (!merged.empty()) shapes = merged;
      }
    } catch (...) {
    }
  }
  for (const TopoDS_Face &shapeFace : shapes) {
    GProp_GProps props;
    BRepGProp::SurfaceProperties(shapeFace, props);
    const double reach = 2 * (diagonal + props.CentreOfMass().Distance(gp_Pnt((lo.X() + hi.X()) / 2, (lo.Y() + hi.Y()) / 2, (lo.Z() + hi.Z()) / 2))) + 1;
    gp_Trsf back;
    back.SetTranslation(gp_Vec(dir) * -reach);
    BRepPrimAPI_MakePrism prism(TopoDS::Face(shapeFace.Moved(TopLoc_Location(back))), gp_Vec(dir) * (2 * reach));
    prism.Build();
    if (!prism.IsDone()) {
      setError("could not draw the profile through the body");
      return 0;
    }
    builder.Add(prisms, prism.Shape());
  }
  Bnd_Box prismBox;
  BRepBndLib::Add(prisms, prismBox);
  // With wrapping, the middle of all the profiles together is where the sketch touches a round face.
  gp_Pnt wrapCentre;
  {
    Bnd_Box all;
    for (Profile *p : ps) BRepBndLib::Add(p->face, all);
    const gp_Pnt a = all.CornerMin(), z = all.CornerMax();
    wrapCentre = gp_Pnt((a.X() + z.X()) / 2, (a.Y() + z.Y()) / 2, (a.Z() + z.Z()) / 2);
  }

  // The profiles' footprint seen along the direction, as a range on two axes square to it (a little wider than they are).
  const gp_Ax2 viewAxes(gp_Pnt(0, 0, 0), dir);
  auto spanOf = [&](const Bnd_Box &bb, double r[4]) {
    r[0] = r[2] = 1e300;
    r[1] = r[3] = -1e300;
    const gp_Pnt a = bb.CornerMin(), z = bb.CornerMax();
    for (int k = 0; k < 8; ++k) {
      const gp_Vec p((k & 1) ? z.X() : a.X(), (k & 2) ? z.Y() : a.Y(), (k & 4) ? z.Z() : a.Z());
      const double x = p.Dot(gp_Vec(viewAxes.XDirection())), y = p.Dot(gp_Vec(viewAxes.YDirection()));
      r[0] = std::min(r[0], x); r[1] = std::max(r[1], x);
      r[2] = std::min(r[2], y); r[3] = std::max(r[3], y);
    }
  };
  double footprint[4];
  {
    Bnd_Box all;
    for (const TopoDS_Face &f : shapes) BRepBndLib::Add(f, all);
    spanOf(all, footprint);
  }
  auto overlapsFootprint = [&](const Bnd_Box &bb) {
    double r[4];
    spanOf(bb, r);
    const double pad = 1e-4;
    return r[0] <= footprint[1] + pad && r[1] >= footprint[0] - pad && r[2] <= footprint[3] + pad && r[3] >= footprint[2] - pad;
  };

  // The parts of the faces inside the prisms that face the sketch: the profile as it lies on the surface.
  TopoDS_Compound patches;
  builder.MakeCompound(patches);
  int patchCount = 0;
  for (const TopoDS_Face &face : targets) {
    TopoDS_Compound wrapped;
    if (wrap && wrapOntoCylinder(face, ps, wrapCentre, dir, wrapped)) {
      BRepAlgoAPI_Common common(face, wrapped);
      if (!common.IsDone() || common.HasErrors()) {
        setError("could not wrap onto a face of the body");
        return 0;
      }
      NCollection_Map<TopoDS_Shape, TopTools_ShapeMapHasher> seen;
      for (TopExp_Explorer ex(common.Shape(), TopAbs_FACE); ex.More(); ex.Next()) {
        const TopoDS_Face piece = TopoDS::Face(ex.Current());
        if (!seen.Add(piece)) continue;
        GProp_GProps props;
        BRepGProp::SurfaceProperties(piece, props);
        if (props.Mass() < 1e-6) continue;
        builder.Add(patches, piece);
        ++patchCount;
      }
      continue;
    }
    Bnd_Box faceBox;
    BRepBndLib::Add(face, faceBox);
    if (faceBox.IsOut(prismBox)) continue;
    // Seen along the direction, a face that does not overlap the profiles' footprint has nothing under them.
    if (!overlapsFootprint(faceBox)) continue;
    // The profiles' prisms go in as separate tools: letters and the pieces of a drawing touch and overlap, and one
    // compound of overlapping solids is refused by the boolean.
    BRepAlgoAPI_Common common;
    {
      ShapeList objects, tools;
      objects.Append(face);
      for (TopoDS_Iterator it(prisms); it.More(); it.Next()) tools.Append(it.Value());
      common.SetArguments(objects);
      common.SetTools(tools);
      common.Build();
    }
    if (!common.IsDone() || common.HasErrors()) {
      setError("could not project onto a face of the body");
      return 0;
    }
    NCollection_Map<TopoDS_Shape, TopTools_ShapeMapHasher> seen;
    for (TopExp_Explorer ex(common.Shape(), TopAbs_FACE); ex.More(); ex.Next()) {
      const TopoDS_Face piece = TopoDS::Face(ex.Current());
      if (!seen.Add(piece)) continue;
      GProp_GProps props;
      BRepGProp::SurfaceProperties(piece, props);
      if (props.Mass() < 1e-6) continue;
      gp_Pnt on;
      gp_Dir normal;
      if (!faceNormalNear(piece, props.CentreOfMass(), on, normal)) continue;
      if (normal.Dot(dir) > -0.02) continue;  // faces away from, or edge-on to, the sketch
      builder.Add(patches, piece);
      ++patchCount;
    }
  }
  if (patchCount == 0) {
    setError("nothing to project onto: no face the sketch looks at is under the profile");
    return 0;
  }
  // The seam of a round face can split a piece in two.
  TopoDS_Shape merged = patches;
  {
    ShapeUpgrade_UnifySameDomain unify(patches, true, true, false);
    unify.Build();
    if (!unify.Shape().IsNull()) merged = unify.Shape();
  }

  // A little past the surface the other way, so the relief overlaps the body instead of just touching it.
  const double h = std::fabs(height);
  const double overlap = std::min(0.1, 0.5 * h);
  const double from = height > 0 ? -overlap : -h, to = height > 0 ? h : overlap;
  TopoDS_Compound relief;
  builder.MakeCompound(relief);
  bool first = true;
  std::vector<Named> names;
  for (TopExp_Explorer ex(merged, TopAbs_FACE); ex.More(); ex.Next()) {
    const TopoDS_Face patch = TopoDS::Face(ex.Current());
    GProp_GProps props;
    BRepGProp::SurfaceProperties(patch, props);
    gp_Pnt on;
    gp_Dir normal;
    if (!faceNormalNear(patch, props.CentreOfMass(), on, normal)) continue;
    // The relief is built on the side the orientation says; check that is the side wanted and turn it round if not.
    const gp_Pnt middle = on.Translated(gp_Vec(normal) * ((from + to) / 2));
    TopoDS_Shape solid = thickenPatch(patch, from, to);
    if (solid.IsNull()) solid = thickenPatch(patch, std::min(from, 0.0), to);  // some surfaces won't offset the other way
    if (!solid.IsNull() && !solidHolds(solid, middle)) {
      TopoDS_Shape turned = thickenPatch(patch, -to, -from);
      if (!turned.IsNull() && solidHolds(turned, middle)) solid = turned;
    }
    if (solid.IsNull()) continue;
    builder.Add(relief, solid);
    if (first) {
      handle[0] = on.X(); handle[1] = on.Y(); handle[2] = on.Z();
      handle[3] = normal.X(); handle[4] = normal.Y(); handle[5] = normal.Z();
      first = false;
    }
    for (TopExp_Explorer f(solid, TopAbs_FACE); f.More(); f.Next()) names.push_back({f.Current(), feat + ".relief"});
  }
  if (first) {
    setError("the surface could not be thickened here · try a smaller height");
    return 0;
  }
  // The pieces of a relief (a flat patch, a curved one) meet in a wall each; cut out as they are, the two coincident
  // walls would stay behind as a thin membrane across the floor. Joined into one solid they are gone.
  TopoDS_Shape result = relief;
  int solids = 0;
  for (TopExp_Explorer ex(relief, TopAbs_SOLID); ex.More(); ex.Next()) ++solids;
  if (solids > 1) {
    ShapeList args, tools;
    bool firstSolid = true;
    for (TopExp_Explorer ex(relief, TopAbs_SOLID); ex.More(); ex.Next()) {
      if (firstSolid) args.Append(ex.Current());
      else tools.Append(ex.Current());
      firstSolid = false;
    }
    BRepAlgoAPI_Fuse fuse;
    fuse.SetArguments(args);
    fuse.SetTools(tools);
    fuse.SetFuzzyValue(1e-6);
    fuse.Build();
    if (fuse.IsDone() && !fuse.HasErrors()) {
      std::vector<Named> carried;
      carry(fuse, names, carried);
      result = unify(fuse.Shape(), carried);
      names = carried;
    }
  }
  return storeChecked(result, names, feat + ".relief", "the projection produced an invalid solid");
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

bool sk_body_edge_circle(SKHandle body, const char *edgeName, double out[14]) {
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
  if (c.GetType() != GeomAbs_Circle) {
    setError("that edge isn't circular");
    return false;
  }
  gp_Circ circ = c.Circle();
  gp_Pnt m = circ.Location(), p = c.Value(c.FirstParameter()), q = c.Value(c.LastParameter());
  gp_Dir n = circ.Axis().Direction();
  out[0] = m.X(); out[1] = m.Y(); out[2] = m.Z();
  out[3] = n.X(); out[4] = n.Y(); out[5] = n.Z();
  out[6] = circ.Radius();
  out[7] = p.X(); out[8] = p.Y(); out[9] = p.Z();
  out[10] = q.X(); out[11] = q.Y(); out[12] = q.Z();
  out[13] = std::abs(c.LastParameter() - c.FirstParameter() - 2 * M_PI) < 1e-7 ? 1 : 0;
  return true;
  SK_CATCH(false)
}

/// Any edge sampled at `n + 1` evenly spaced parameters: each sample is a point and the derivative with respect to the
/// parameter running 0...1 (so a Hermite spline through the samples reproduces the edge). out holds (n + 1) * 6 numbers.
bool sk_body_edge_sample(SKHandle body, const char *edgeName, int n, double *out) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b || n < 1) return false;
  auto it = b->edgeIndex.find(edgeName);
  if (it == b->edgeIndex.end()) {
    setError(std::string("edge not found: ") + edgeName);
    return false;
  }
  BRepAdaptor_Curve c(TopoDS::Edge(b->edges(it->second + 1)));
  const double t0 = c.FirstParameter(), span = c.LastParameter() - t0;
  for (int i = 0; i <= n; i++) {
    gp_Pnt p;
    gp_Vec d;
    c.D1(t0 + span * i / n, p, d);
    out[i * 6] = p.X(); out[i * 6 + 1] = p.Y(); out[i * 6 + 2] = p.Z();
    out[i * 6 + 3] = d.X() * span; out[i * 6 + 4] = d.Y() * span; out[i * 6 + 5] = d.Z() * span;
  }
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

SKHandle sk_scale(SKHandle body, double ox, double oy, double oz, double factor) {
  SK_TRY
  if (!(factor > 1e-9)) {
    setError("the scale factor must be more than zero");
    return 0;
  }
  gp_Trsf t;
  t.SetScale(gp_Pnt(ox, oy, oz), factor);
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

/// The separate solids a shape is made of. A solid whose shells don't touch (two blocks that were joined into one
/// body without meeting) comes out as one solid per outer shell, with any void shell given to the outer shell around it.
static std::vector<TopoDS_Shape> componentSolids(const TopoDS_Shape &shape) {
  std::vector<TopoDS_Shape> out;
  for (TopExp_Explorer ex(shape, TopAbs_SOLID); ex.More(); ex.Next()) {
    std::vector<TopoDS_Shell> shells;
    for (TopExp_Explorer sx(ex.Current(), TopAbs_SHELL); sx.More(); sx.Next()) shells.push_back(TopoDS::Shell(sx.Current()));
    if (shells.size() < 2) {
      out.push_back(ex.Current());
      continue;
    }
    std::vector<TopoDS_Solid> outers, voids;
    for (const TopoDS_Shell &sh : shells) {
      BRepBuilderAPI_MakeSolid mk(sh);
      GProp_GProps props;
      BRepGProp::VolumeProperties(mk.Solid(), props);
      (props.Mass() >= 0 ? outers : voids).push_back(mk.Solid());
    }
    if (outers.size() < 2) {  // one body with hollows inside: stays whole
      out.push_back(ex.Current());
      continue;
    }
    std::vector<std::vector<TopoDS_Shell>> owned(outers.size());
    for (size_t i = 0; i < outers.size(); ++i) owned[i].push_back(TopoDS::Shell(TopoDS_Iterator(outers[i]).Value()));
    for (const TopoDS_Solid &v : voids) {
      TopExp_Explorer vx(v, TopAbs_VERTEX);
      if (!vx.More()) continue;
      const gp_Pnt at = BRep_Tool::Pnt(TopoDS::Vertex(vx.Current()));
      for (size_t i = 0; i < outers.size(); ++i) {
        BRepClass3d_SolidClassifier cls(outers[i], at, 1e-6);
        if (cls.State() == TopAbs_IN || cls.State() == TopAbs_ON) {
          owned[i].push_back(TopoDS::Shell(TopoDS_Iterator(v).Value()));
          break;
        }
      }
    }
    for (size_t i = 0; i < outers.size(); ++i) {
      if (owned[i].size() == 1) {
        out.push_back(outers[i]);
        continue;
      }
      BRep_Builder bb;
      TopoDS_Solid solid;
      bb.MakeSolid(solid);
      for (const TopoDS_Shell &sh : owned[i]) bb.Add(solid, sh);
      out.push_back(solid);
    }
  }
  return out;
}

int sk_split(SKHandle body, SKHandle toolBody, const char *toolFace, double ox, double oy, double oz, double nx, double ny,
             double nz, const char *featureId, SKHandle *out, int max) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return 0;
  const std::string feat = featureOrDefault(featureId, "split");
  const gp_Dir dir = (nx * nx + ny * ny + nz * nz) > 1e-12 ? gp_Dir(nx, ny, nz) : gp_Dir(0, 0, 1);

  // The tool: a face of another body as it is, or a plane made big enough to run clean through the body.
  TopoDS_Face tool;
  std::shared_ptr<Object> keepTool;
  if (toolBody) {
    Body *t;
    keepTool = lookup(toolBody, t);
    if (!t) return 0;
    auto it = t->faceIndex.find(toolFace ? toolFace : "");
    if (it == t->faceIndex.end()) {
      setError(std::string("face not found: ") + (toolFace ? toolFace : ""));
      return 0;
    }
    tool = TopoDS::Face(t->faces(it->second + 1));
  } else {
    Bnd_Box box;
    BRepBndLib::Add(b->shape, box);
    if (box.IsVoid()) {
      setError("the body is empty");
      return 0;
    }
    double x0, y0, z0, x1, y1, z1;
    box.Get(x0, y0, z0, x1, y1, z1);
    const gp_Pnt middle((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2);
    const double reach = gp_Pnt(x0, y0, z0).Distance(gp_Pnt(x1, y1, z1)) + 1.0;
    // The plane's own point nearest the body's middle, so the square sits over the body however far the origin is.
    const gp_Pln plane(gp_Pnt(ox, oy, oz), dir);
    const gp_Vec toMiddle(plane.Location(), middle);
    const gp_Pnt centre = middle.Translated(-gp_Vec(dir) * toMiddle.Dot(gp_Vec(dir)));
    tool = BRepBuilderAPI_MakeFace(gp_Pln(centre, dir), -reach, reach, -reach, reach).Face();
  }

  BRepAlgoAPI_Splitter sp;
  ShapeList args, tools;
  args.Append(b->shape);
  tools.Append(tool);
  sp.SetArguments(args);
  sp.SetTools(tools);
  sp.SetRunParallel(true);
  sp.Build();
  if (!sp.IsDone() || sp.HasErrors()) {
    setError("could not split the body");
    return 0;
  }

  // The faces the tool leaves inside the body are the new ones, one on each side of the cut.
  std::vector<Named> names;
  carry(sp, namedFaces(*b), names);
  std::vector<Named> cuts;
  const ShapeList &inside = sp.Modified(tool);
  for (const TopoDS_Shape &c : inside) cuts.push_back({c, feat + ".split"});

  struct Piece {
    TopoDS_Shape solid;
    std::tuple<long long, long long, long long> key;
    long long along;
  };
  std::vector<Piece> pieces;
  for (const TopoDS_Shape &solid : componentSolids(sp.Shape())) {
    GProp_GProps props;
    BRepGProp::VolumeProperties(solid, props);
    if (props.Mass() <= 1e-9) continue;
    const gp_Pnt c = props.CentreOfMass();
    auto q = [](double v) { return std::llround(v * 1e4); };
    pieces.push_back({solid, {q(c.X()), q(c.Y()), q(c.Z())}, q(gp_Vec(gp_Pnt(0, 0, 0), c).Dot(gp_Vec(dir)))});
  }
  if (pieces.empty()) {
    setError("the split left nothing");
    return 0;
  }
  // Pieces come in a fixed order (along the tool's normal, then by position) so a rebuild names them the same.
  std::sort(pieces.begin(), pieces.end(), [&](const Piece &x, const Piece &y) {
    return toolBody ? x.key < y.key : std::tie(x.along, x.key) < std::tie(y.along, y.key);
  });

  int written = 0;
  for (const Piece &p : pieces) {
    if (written >= max) break;
    // Each piece is a copy of its own, so two bodies never share a face (they are meshed on different threads).
    BRepBuilderAPI_Copy copy(p.solid, true, false);
    std::vector<Named> mine;
    ShapeIndexedMap inPiece;
    TopExp::MapShapes(p.solid, TopAbs_FACE, inPiece);
    for (const Named &n : names)
      if (inPiece.Contains(n.shape)) mine.push_back({copy.ModifiedShape(n.shape), n.name});
    for (const Named &n : cuts)
      if (inPiece.Contains(n.shape)) mine.push_back({copy.ModifiedShape(n.shape), n.name});
    out[written++] = store(makeBody(copy.Shape(), mine, feat));
  }
  return written;
  SK_CATCH(0)
}

/// The cut a plane makes through a body: an edge-only body whose edges are the section curves. Each is named after the
/// face of the body it lies on (a face cut in several places gets "#2", "#3"... in positional order), so a rebuild
/// finds the same piece again.
SKHandle sk_body_section(SKHandle body, double ox, double oy, double oz, double nx, double ny, double nz, const char *featureId) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return 0;
  const std::string feat = featureOrDefault(featureId, "section");
  const gp_Dir dir = (nx * nx + ny * ny + nz * nz) > 1e-12 ? gp_Dir(nx, ny, nz) : gp_Dir(0, 0, 1);
  Bnd_Box box;
  BRepBndLib::Add(b->shape, box);
  if (box.IsVoid()) {
    setError("the body is empty");
    return 0;
  }
  double x0, y0, z0, x1, y1, z1;
  box.Get(x0, y0, z0, x1, y1, z1);
  const gp_Pnt middle((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2);
  const double reach = gp_Pnt(x0, y0, z0).Distance(gp_Pnt(x1, y1, z1)) + 1.0;
  const gp_Pln plane(gp_Pnt(ox, oy, oz), dir);
  const gp_Vec toMiddle(plane.Location(), middle);
  const gp_Pnt centre = middle.Translated(-gp_Vec(dir) * toMiddle.Dot(gp_Vec(dir)));
  const TopoDS_Face tool = BRepBuilderAPI_MakeFace(gp_Pln(centre, dir), -reach, reach, -reach, reach).Face();

  BRepAlgoAPI_Section sec(b->shape, tool, false);
  sec.Approximation(false);
  sec.ComputePCurveOn1(false);
  sec.Build();
  if (!sec.IsDone() || sec.HasErrors()) {
    setError("could not cut the body with the plane");
    return 0;
  }

  // The edges the section made, named after the face each came from.
  ShapeIndexedMap found;
  TopExp::MapShapes(sec.Shape(), TopAbs_EDGE, found);
  std::vector<std::string> names(found.Extent(), "");
  for (int i = 1; i <= b->faces.Extent(); ++i) {
    for (const TopoDS_Shape &g : sec.Generated(b->faces(i))) {
      const int idx = g.ShapeType() == TopAbs_EDGE ? found.FindIndex(g) : 0;
      if (idx > 0 && names[idx - 1].empty()) names[idx - 1] = b->faceNames[i - 1];
    }
  }
  for (auto &n : names)
    if (n.empty()) n = feat + ".edge";
  if (names.empty()) {
    setError("the plane doesn't cut the body");
    return 0;
  }
  uniquify(found, names);

  Body out;
  BRep_Builder builder;
  TopoDS_Compound compound;
  builder.MakeCompound(compound);
  for (int i = 1; i <= found.Extent(); ++i) builder.Add(compound, found(i));
  out.shape = compound;
  TopExp::MapShapes(compound, TopAbs_EDGE, out.edges);
  out.edgeNames.assign(out.edges.Extent(), "");
  for (int i = 1; i <= found.Extent(); ++i) {
    const int idx = out.edges.FindIndex(found(i));
    if (idx > 0) out.edgeNames[idx - 1] = names[i - 1];
  }
  out.edgeHidden.assign(out.edges.Extent(), false);
  for (int i = 0; i < (int)out.edgeNames.size(); ++i) out.edgeIndex[out.edgeNames[i]] = i;
  return store(std::move(out));
  SK_CATCH(0)
}

int sk_split_parts(SKHandle body, const char *featureId, SKHandle *out, int max) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return 0;
  const std::string feat = featureOrDefault(featureId, "split");
  struct Piece {
    TopoDS_Shape solid;
    long long volume;
    std::tuple<long long, long long, long long> key;
  };
  std::vector<Piece> pieces;
  for (const TopoDS_Shape &solid : componentSolids(b->shape)) {
    GProp_GProps props;
    BRepGProp::VolumeProperties(solid, props);
    if (props.Mass() <= 1e-9) continue;
    const gp_Pnt c = props.CentreOfMass();
    auto q = [](double v) { return std::llround(v * 1e4); };
    pieces.push_back({solid, q(props.Mass()), {q(c.X()), q(c.Y()), q(c.Z())}});
  }
  if (pieces.empty()) {
    setError("the body has no solid in it");
    return 0;
  }
  // The biggest part keeps the body's identity; equal parts go by position, so a rebuild names them the same.
  std::sort(pieces.begin(), pieces.end(), [](const Piece &x, const Piece &y) {
    return x.volume != y.volume ? x.volume > y.volume : x.key < y.key;
  });
  const std::vector<Named> names = namedFaces(*b);
  int written = 0;
  for (const Piece &p : pieces) {
    if (written >= max) break;
    BRepBuilderAPI_Copy copy(p.solid, true, false);
    std::vector<Named> mine;
    ShapeIndexedMap inPiece;
    TopExp::MapShapes(p.solid, TopAbs_FACE, inPiece);
    for (const Named &n : names)
      if (inPiece.Contains(n.shape)) mine.push_back({copy.ModifiedShape(n.shape), n.name});
    out[written++] = store(makeBody(copy.Shape(), mine, feat));
  }
  return written;
  SK_CATCH(0)
}

SKHandle sk_fillet(SKHandle body, const char *const *edgeNames, int count, double radius, const char *featureId) {
  SK_TRY
  if (radius <= Precision::Confusion()) {
    setError("fillet radius must be positive");
    return 0;
  }
  // OCCT ends a round at a vertex only when the two faces there are tangent to within `tangency` (0.01 radian by
  // default), and takes anything else for a corner it cannot finish. A crease that fades out where two faces run into
  // each other almost tangent (a swept round that misses the side wall by a hundredth of a millimetre leaves one,
  // with the faces 4 degrees apart at its end) fails at every size, so a wider tangency is tried after the default.
  auto round = [&](SKHandle on, double r, double tangency) {
    return edgeFeature<BRepFilletAPI_MakeFillet>(on, edgeNames, count, featureOrDefault(featureId, "fillet"), "fillet",
                                                 [&](BRepFilletAPI_MakeFillet &mk, const TopoDS_Edge &e) {
                                                   if (tangency > 0) mk.SetParams(tangency, 1.0e-4, 1.e-5, 1.e-4, 1.e-5, 1.e-3);
                                                   mk.Add(r, e);
                                                 });
  };
  constexpr double kFadingCreaseTangency = 0.15;  // about 8.6 degrees
  SKHandle made = round(body, radius, 0);
  // A round that uses up a whole face (1 mm on a 2 mm strip) meets itself exactly, and OCCT can fail there on
  // spline faces although a hair less builds. A millionth less is the same round for any real part.
  if (!made) {
    const std::string why = g_error;
    made = round(body, radius * (1 - 1e-6), 0);
    if (!made) made = round(body, radius, kFadingCreaseTangency);
    if (!made) made = round(body, radius * (1 - 1e-6), kFadingCreaseTangency);
    if (!made) {
      // Last, the same body with its faces in the opposite order (see reverseFaceOrder).
      Body *b;
      auto keep = lookup(body, b);
      Body reordered;
      if (b && reverseFaceOrder(*b, reordered)) {
        const SKHandle h = store(std::move(reordered));
        made = round(h, radius, 0);
        if (!made) made = round(h, radius, kFadingCreaseTangency);
        std::lock_guard<std::mutex> lock(g_mutex);
        g_objects.erase(h);
      }
    }
    if (!made) setError(why);
  }
  return made;
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
      [&](BRepFilletAPI_MakeChamfer &mk, const TopoDS_Edge &e) { mk.Add(distance, e); }, distance);
  SK_CATCH(0)
}

/// The two faces at an edge, the one the first chamfer distance is measured on first: the named one when it is
/// one of them, else the one with the smaller name (so the choice survives a rebuild); `flip` takes the other.
static bool edgeSides(const Body &b, const ShapeToShapes &edgeFaces, const TopoDS_Edge &e, const char *named, bool flip,
                      TopoDS_Face &first, TopoDS_Face &second) {
  if (!edgeFaces.Contains(e) || edgeFaces.FindFromKey(e).Extent() != 2) return false;
  std::vector<std::pair<std::string, TopoDS_Face>> sides;
  for (const TopoDS_Shape &fs : edgeFaces.FindFromKey(e)) {
    const int idx = b.faces.FindIndex(fs);
    sides.push_back({idx > 0 ? b.faceNames[idx - 1] : std::string(), TopoDS::Face(fs)});
  }
  std::sort(sides.begin(), sides.end(), [](const auto &x, const auto &y) { return x.first < y.first; });
  int pick = (named && *named && sides[1].first == named) ? 1 : 0;
  if (flip) pick = 1 - pick;
  first = sides[pick].second;
  second = sides[1 - pick].second;
  return true;
}

/// The same for one edge, when there is no map of the body's edges to hand.
static bool edgeSides(const Body &b, const TopoDS_Edge &e, const char *named, bool flip, TopoDS_Face &first, TopoDS_Face &second) {
  ShapeToShapes edgeFaces;
  TopExp::MapShapesAndUniqueAncestors(b.shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
  return edgeSides(b, edgeFaces, e, named, flip, first, second);
}

SKHandle sk_chamfer_ex(SKHandle body, const char *const *edgeNames, const char *const *faceNames, int count,
                       SKChamferMode mode, double first, double second, bool flip, const char *featureId) {
  SK_TRY
  if (mode == SK_CHAMFER_EQUAL) return sk_chamfer(body, edgeNames, count, first, featureId);
  if (first <= Precision::Confusion() || (mode == SK_CHAMFER_TWO_DISTANCES && second <= Precision::Confusion())) {
    setError("chamfer distance must be positive");
    return 0;
  }
  if (mode == SK_CHAMFER_DISTANCE_ANGLE && (second <= 1e-6 || second >= M_PI / 2 - 1e-6)) {
    setError("chamfer angle must be between 0 and 90 degrees");
    return 0;
  }
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return 0;
  // Which face each edge's first distance is on, worked out first: an edge that isn't between two faces is an error.
  std::vector<TopoDS_Face> onFirst;
  ShapeToShapes edgeFaces;  // once for all the edges, not once for each
  TopExp::MapShapesAndUniqueAncestors(b->shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
  for (int k = 0; k < count; ++k) {
    auto it = b->edgeIndex.find(edgeNames[k]);
    if (it == b->edgeIndex.end()) {
      setError(std::string("edge not found: ") + edgeNames[k]);
      return 0;
    }
    TopoDS_Face f1, f2;
    if (!edgeSides(*b, edgeFaces, TopoDS::Edge(b->edges(it->second + 1)), faceNames ? faceNames[k] : nullptr, flip, f1, f2)) {
      setError("the edge must join two faces");
      return 0;
    }
    onFirst.push_back(f1);
  }
  int k = 0;
  return edgeFeature<BRepFilletAPI_MakeChamfer>(
      body, edgeNames, count, featureOrDefault(featureId, "chamfer"), "chamfer", [&](BRepFilletAPI_MakeChamfer &mk, const TopoDS_Edge &e) {
        if (mode == SK_CHAMFER_TWO_DISTANCES) mk.Add(first, second, e, onFirst[k]);
        else mk.AddDA(first, second, e, onFirst[k]);
        ++k;
      }, 0, true);  // the faces picked belong to this body: no healed copy to retry on
  SK_CATCH(0)
}

bool sk_edge_round_limit(SKHandle body, const char *const *edgeNames, int count, double *out) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return false;
  std::vector<TopoDS_Edge> edges;
  for (int k = 0; k < count; ++k) {
    auto it = b->edgeIndex.find(edgeNames[k]);
    if (it == b->edgeIndex.end()) {
      setError(std::string("edge not found: ") + edgeNames[k]);
      return false;
    }
    edges.push_back(TopoDS::Edge(b->edges(it->second + 1)));
  }
  return cornerRadiusLimit(*b, edges, *out);
  SK_CATCH(false)
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
  const gp_Dir n = planeNormal(f, s.Plane());
  const gp_Pnt &o = pos.Location();
  const gp_Dir &x = pos.XDirection();
  *out = SKFrame{o.X(), o.Y(), o.Z(), n.X(), n.Y(), n.Z(), x.X(), x.Y(), x.Z()};
  return true;
  SK_CATCH(false)
}

namespace {
/// Where a line meets a face: the hit nearest `origin` (either way along the line). False if it misses.
bool lineHitsFace(const TopoDS_Face &f, const gp_Pnt &origin, const gp_Dir &dir, gp_Pnt &hit) {
  IntCurvesFace_ShapeIntersector inter;
  inter.Load(f, 1e-6);
  inter.Perform(gp_Lin(origin, dir), -1e6, 1e6);
  if (!inter.IsDone() || inter.NbPnt() < 1) return false;
  int best = 1;
  for (int i = 2; i <= inter.NbPnt(); ++i)
    if (std::fabs(inter.WParameter(i)) < std::fabs(inter.WParameter(best))) best = i;
  hit = inter.Pnt(best);
  return true;
}

/// The tangent plane of a curved face at the point of its surface nearest the middle of its outline: the
/// frame hole positions on a curved face are measured in. x is level when it can be (as for sketch planes).
bool curvedAnchor(const TopoDS_Face &f, gp_Pnt &on, gp_Dir &n, gp_Dir &x) {
  // The middle of the face's parameter range: a face that goes all the way round (a cylinder, a sphere) has its
  // centre of mass on the axis or the centre, which is no point of the surface to start from.
  double u0, u1, v0, v1;
  BRepTools::UVBounds(f, u0, u1, v0, v1);
  BRepLProp_SLProps props(BRepAdaptor_Surface(f), 0.5 * (u0 + u1), 0.5 * (v0 + v1), 1, 1e-6);
  if (!props.IsNormalDefined()) return false;
  n = props.Normal();
  if (f.Orientation() == TopAbs_REVERSED) n.Reverse();
  on = props.Value();
  gp_Vec xv = gp_Vec(0, 0, 1).Crossed(gp_Vec(n));
  if (xv.SquareMagnitude() < 1e-12) xv = gp_Vec(1, 0, 0) - gp_Vec(n) * n.X();
  x = gp_Dir(xv);
  return true;
}
}  // namespace

bool sk_body_face_tangent_frame(SKHandle body, const char *faceName, SKFrame *out) {
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
  if (BRepAdaptor_Surface(f).GetType() == GeomAbs_Plane) return sk_body_face_frame(body, faceName, out);
  gp_Pnt o; gp_Dir n, x;
  if (!curvedAnchor(f, o, n, x)) {
    setError(std::string("no surface normal on face: ") + faceName);
    return false;
  }
  *out = SKFrame{o.X(), o.Y(), o.Z(), n.X(), n.Y(), n.Z(), x.X(), x.Y(), x.Z()};
  return true;
  SK_CATCH(false)
}

bool sk_body_face_hit(SKHandle body, const char *faceName, const double origin[3], const double dir[3], double out[3]) {
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
  gp_Pnt hit;
  // The nearest hit in front of the ray, not behind it.
  IntCurvesFace_ShapeIntersector inter;
  inter.Load(f, 1e-6);
  inter.Perform(gp_Lin(gp_Pnt(origin[0], origin[1], origin[2]), gp_Dir(dir[0], dir[1], dir[2])), 0, 1e7);
  if (!inter.IsDone() || inter.NbPnt() < 1) {
    setError("the ray misses the face");
    return false;
  }
  int best = 1;
  for (int i = 2; i <= inter.NbPnt(); ++i)
    if (inter.WParameter(i) < inter.WParameter(best)) best = i;
  hit = inter.Pnt(best);
  out[0] = hit.X(); out[1] = hit.Y(); out[2] = hit.Z();
  return true;
  SK_CATCH(false)
}

bool sk_body_hole_frame(SKHandle body, const char *faceName, double u, double v, double reach, SKFrame *out, double *lift) {
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
  *lift = 0;
  if (BRepAdaptor_Surface(f).GetType() == GeomAbs_Plane) {
    SKFrame fr;
    if (!sk_body_face_frame(body, faceName, &fr)) return false;
    const gp_Vec xa(fr.xx, fr.xy, fr.xz), na(fr.nx, fr.ny, fr.nz), ya = na.Crossed(xa);
    *out = fr;
    out->ox += u * xa.X() + v * ya.X(); out->oy += u * xa.Y() + v * ya.Y(); out->oz += u * xa.Z() + v * ya.Z();
    return true;
  }
  gp_Pnt a; gp_Dir n, x;
  if (!curvedAnchor(f, a, n, x)) {
    setError(std::string("no surface normal on face: ") + faceName);
    return false;
  }
  const gp_Vec xv(x), nv(n), yv = nv.Crossed(xv);
  const gp_Pnt flat = a.Translated(xv * u + yv * v);
  // Straight "down" onto the surface from the tangent plane (what you see when looking at the face); where that
  // finds nothing (round the side of a cylinder) the nearest point of the surface.
  gp_Pnt on;
  if (!lineHitsFace(f, flat, n, on)) {
    gp_Dir nn;
    if (!faceNormalNear(f, flat, on, nn)) {
      setError("the hole is off the face");
      return false;
    }
  }
  gp_Pnt on2; gp_Dir n2;
  if (!faceNormalNear(f, on, on2, n2)) {
    setError("no surface normal where the hole goes");
    return false;
  }
  gp_Vec x2 = xv - gp_Vec(n2) * xv.Dot(gp_Vec(n2));
  if (x2.SquareMagnitude() < 1e-12) x2 = yv - gp_Vec(n2) * yv.Dot(gp_Vec(n2));
  const gp_Dir xd(x2);
  *out = SKFrame{on2.X(), on2.Y(), on2.Z(), n2.X(), n2.Y(), n2.Z(), xd.X(), xd.Y(), xd.Z()};
  // How far the surface climbs above the flat top of the tool, within the hole's reach (a concave surface rises
  // away from the middle, and the tool would leave a skin there).
  const gp_Vec yd = gp_Vec(n2).Crossed(gp_Vec(xd));
  double rise = 0;
  for (int k = 0; k < 16 && reach > 1e-9; ++k) {
    const double ang = 2 * M_PI * k / 16;
    const gp_Pnt around = on2.Translated(gp_Vec(xd) * (reach * std::cos(ang)) + yd * (reach * std::sin(ang)));
    gp_Pnt h;
    if (lineHitsFace(f, around, n2, h)) rise = std::max(rise, gp_Vec(on2, h).Dot(gp_Vec(n2)));
  }
  *lift = rise;
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

/// Where a face lies from one of its edges, at parameter `t` along it: the face's outward normal there, and the
/// direction across the face away from the edge.
static bool faceSideAt(const TopoDS_Edge &e, const TopoDS_Face &f, double t, gp_Vec &normal, gp_Vec &inward) {
  BRepAdaptor_Curve curve(e);
  const gp_Pnt mid = curve.Value(t);
  BRepAdaptor_Surface surf(f);
  double f0, l0;
  Handle(Geom2d_Curve) pc = BRep_Tool::CurveOnSurface(e, f, f0, l0);
  gp_Pnt2d uv;
  if (!pc.IsNull()) {
    uv = pc->Value(t);
  } else {
    GeomAPI_ProjectPointOnSurf proj(mid, BRep_Tool::Surface(f));
    if (proj.NbPoints() == 0) return false;
    double u, v;
    proj.LowerDistanceParameters(u, v);
    uv = gp_Pnt2d(u, v);
  }
  gp_Pnt p;
  gp_Vec du, dv;
  surf.D1(uv.X(), uv.Y(), p, du, dv);
  normal = du.Crossed(dv);
  if (normal.Magnitude() < 1e-12) return false;
  normal.Normalize();
  if (f.Orientation() == TopAbs_REVERSED) normal.Reverse();
  // The face is on the left of its boundary edges, seen from outside: so across the face is normal x direction,
  // with the direction the edge runs round this face.
  gp_Vec along = curve.DN(t, 1);
  if (along.Magnitude() < 1e-12) return false;
  along.Normalize();
  for (TopExp_Explorer ex(f, TopAbs_EDGE); ex.More(); ex.Next())
    if (ex.Current().IsSame(e)) {
      if (ex.Current().Orientation() == TopAbs_REVERSED) along.Reverse();
      break;
    }
  inward = normal.Crossed(along);
  if (inward.Magnitude() < 1e-12) return false;
  inward.Normalize();
  return true;
}

bool sk_body_chamfer_handle(SKHandle body, const char *edgeName, const char *faceName, bool flip, double out[12]) {
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
  TopoDS_Face f1, f2;
  if (!edgeSides(*b, e, faceName, flip, f1, f2)) {
    setError("the edge must join two faces");
    return false;
  }
  BRepAdaptor_Curve curve(e);
  const double t = 0.5 * (curve.FirstParameter() + curve.LastParameter());
  const gp_Pnt mid = curve.Value(t);
  gp_Vec n1, in1, n2, in2;
  if (!faceSideAt(e, f1, t, n1, in1) || !faceSideAt(e, f2, t, n2, in2)) {
    setError("could not evaluate the faces at this edge");
    return false;
  }
  const double v[12] = {mid.X(), mid.Y(), mid.Z(), in1.X(), in1.Y(), in1.Z(), in2.X(), in2.Y(), in2.Z(), n1.X(), n1.Y(), n1.Z()};
  std::copy(v, v + 12, out);
  return true;
  SK_CATCH(false)
}

/// A solid's volume and centre. The plain integration is up to a percent or two off on a face that is a straight
/// extrusion of a spline of several spans (what a run of merged curves gives), so those solids are measured from
/// a fine mesh of a copy instead; every other solid gets the exact form.
static void accurateVolume(const TopoDS_Shape &shape, GProp_GProps &props) {
  if (hasSplineExtrusion(shape)) {
    BRepBuilderAPI_Copy copy(shape, true, false);  // meshed on a copy: the body itself may be meshed by another thread
    BRepMesh_IncrementalMesh(copy.Shape(), 0.002, false, 0.1, false);
    BRepGProp::VolumeProperties(copy.Shape(), props, false, false, true);
  } else BRepGProp::VolumeProperties(shape, props);
}

double sk_body_volume(SKHandle body) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b) return 0;
  GProp_GProps props;
  accurateVolume(b->shape, props);
  return props.Mass();
  SK_CATCH(0)
}

bool sk_body_is_empty(SKHandle body) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b || b->faces.Extent() == 0) return true;
  // Whatever a cut or common leaves of any size has many faces; only a speck can be thinner than the volume's 1e-9,
  // and a body with a thread has no end of faces to integrate over.
  if (b->faces.Extent() > 64) return false;
  GProp_GProps props;
  accurateVolume(b->shape, props);
  return props.Mass() <= 1e-9;
  SK_CATCH(true)
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

// ----------------------------------------------------------------- measure ---

namespace {
/// The face, the edge or (null name) the whole shape of a body.
bool measuredPiece(Body &b, bool isFace, const char *name, TopoDS_Shape &out) {
  if (!name) {
    out = b.shape;
    return true;
  }
  const auto &index = isFace ? b.faceIndex : b.edgeIndex;
  auto it = index.find(name);
  if (it == index.end()) {
    setError(std::string(isFace ? "face not found: " : "edge not found: ") + name);
    return false;
  }
  out = isFace ? b.faces(it->second + 1) : b.edges(it->second + 1);
  return true;
}

}  // namespace

extern "C++" {
template <class T>
void copyXYZ(double *to, const T &p) { to[0] = p.X(); to[1] = p.Y(); to[2] = p.Z(); }
}

bool sk_measure_element(SKHandle body, bool isFace, const char *name, SKMeasure *out) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  if (!b || !out) return false;
  TopoDS_Shape shape;
  if (!measuredPiece(*b, isFace, name, shape)) return false;
  *out = SKMeasure{};

  Bnd_Box box;
  BRepBndLib::AddOptimal(shape, box, Standard_False, Standard_False);
  if (!box.IsVoid()) box.Get(out->bounds[0], out->bounds[1], out->bounds[2], out->bounds[3], out->bounds[4], out->bounds[5]);

  GProp_GProps props;
  if (!name) {
    out->geom = SK_GEOM_BODY;
    accurateVolume(shape, props);
    out->volume = props.Mass();
    copyXYZ(out->centroid, props.CentreOfMass());
    GProp_GProps surface;
    BRepGProp::SurfaceProperties(shape, surface);
    out->size = surface.Mass();
    return true;
  }

  if (isFace) {
    const TopoDS_Face &f = TopoDS::Face(shape);
    BRepGProp::SurfaceProperties(f, props);
    out->size = props.Mass();
    copyXYZ(out->centroid, props.CentreOfMass());
    GProp_GProps edges;
    BRepGProp::LinearProperties(f, edges);
    out->perimeter = edges.Mass();

    BRepAdaptor_Surface s(f);
    const double v0 = s.FirstVParameter(), v1 = s.LastVParameter();
    switch (s.GetType()) {
      case GeomAbs_Plane: {
        out->geom = SK_GEOM_PLANE;
        const gp_Dir n = planeNormal(f, s.Plane());
        out->hasDirection = true;
        copyXYZ(out->direction, n);
        break;
      }
      case GeomAbs_Cylinder: {
        const gp_Cylinder c = s.Cylinder();
        out->geom = SK_GEOM_CYLINDER;
        out->radius = c.Radius();
        out->length = std::abs(v1 - v0);
        out->hasCenter = out->hasDirection = true;
        copyXYZ(out->center, c.Axis().Location());
        copyXYZ(out->direction, c.Axis().Direction());
        break;
      }
      case GeomAbs_Cone: {
        const gp_Cone c = s.Cone();
        out->geom = SK_GEOM_CONE;
        const double sa = c.SemiAngle();
        out->angle = std::abs(sa);
        out->radius = std::abs(c.RefRadius() + v0 * std::sin(sa));
        out->radius2 = std::abs(c.RefRadius() + v1 * std::sin(sa));
        out->length = std::abs(v1 - v0) * std::cos(sa);
        out->hasCenter = out->hasDirection = true;
        copyXYZ(out->center, c.Axis().Location());
        copyXYZ(out->direction, c.Axis().Direction());
        break;
      }
      case GeomAbs_Sphere: {
        const gp_Sphere sp = s.Sphere();
        out->geom = SK_GEOM_SPHERE;
        out->radius = sp.Radius();
        out->hasCenter = true;
        copyXYZ(out->center, sp.Location());
        break;
      }
      case GeomAbs_Torus: {
        const gp_Torus t = s.Torus();
        out->geom = SK_GEOM_TORUS;
        out->radius = t.MajorRadius();
        out->radius2 = t.MinorRadius();
        out->hasCenter = out->hasDirection = true;
        copyXYZ(out->center, t.Location());
        copyXYZ(out->direction, t.Axis().Direction());
        break;
      }
      default:
        out->geom = SK_GEOM_OTHER;
    }
    return true;
  }

  const TopoDS_Edge &e = TopoDS::Edge(shape);
  BRepGProp::LinearProperties(e, props);
  out->size = props.Mass();
  copyXYZ(out->centroid, props.CentreOfMass());
  BRepAdaptor_Curve c(e);
  const double t0 = c.FirstParameter(), t1 = c.LastParameter();
  out->hasEnds = true;
  copyXYZ(out->start, c.Value(t0));
  copyXYZ(out->end, c.Value(t1));
  switch (c.GetType()) {
    case GeomAbs_Line:
      out->geom = SK_GEOM_LINE;
      out->hasDirection = true;
      copyXYZ(out->direction, c.Line().Direction());
      break;
    case GeomAbs_Circle: {
      const gp_Circ circle = c.Circle();
      const double span = std::abs(t1 - t0);
      out->geom = span > 2 * M_PI - 1e-6 ? SK_GEOM_CIRCLE : SK_GEOM_ARC;
      out->radius = circle.Radius();
      out->angle = std::min(span, 2 * M_PI);
      out->hasCenter = out->hasDirection = true;
      copyXYZ(out->center, circle.Location());
      copyXYZ(out->direction, circle.Axis().Direction());
      break;
    }
    default:
      out->geom = SK_GEOM_OTHER;
  }
  return true;
  SK_CATCH(false)
}

bool sk_measure_distance(SKHandle bodyA, bool isFaceA, const char *nameA, SKHandle bodyB, bool isFaceB, const char *nameB,
                         double out[7]) {
  SK_TRY
  Body *a, *b;
  auto keepA = lookup(bodyA, a);
  auto keepB = lookup(bodyB, b);
  if (!a || !b) return false;
  TopoDS_Shape sa, sb;
  if (!measuredPiece(*a, isFaceA, nameA, sa) || !measuredPiece(*b, isFaceB, nameB, sb)) return false;
  BRepExtrema_DistShapeShape d(sa, sb);
  if (!d.IsDone() || d.NbSolution() < 1) {
    setError("could not measure the distance");
    return false;
  }
  out[0] = d.Value();
  copyXYZ(out + 1, d.PointOnShape1(1));
  copyXYZ(out + 4, d.PointOnShape2(1));
  return true;
  SK_CATCH(false)
}

bool sk_body_is_valid(SKHandle body) {
  SK_TRY
  Body *b;
  auto keep = lookup(body, b);
  return b && BRepCheck_Analyzer(b->shape, true, true).IsValid();
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

/// Makes a body of the solids read from a file: one solid as it is, several as a compound. A file has no feature
/// history, so faces are named by their place in it, which a rebuild repeats.
static SKHandle storeImported(const std::vector<TopoDS_Shape> &solids, const std::string &feat) {
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
  std::vector<Named> names;
  ShapeIndexedMap faces;
  TopExp::MapShapes(shape, TopAbs_FACE, faces);
  for (int i = 1; i <= faces.Extent(); ++i) names.push_back({faces(i), feat + ".face" + std::to_string(i)});
  return store(makeBody(shape, names, feat));
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
    setError("this isn't a STEP file SimplMaker can read");
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

  return storeImported(solids, feat);
  SK_CATCH(0)
}

/// Reads an STL file (binary or ASCII) into a body. A mesh is only triangles, so each becomes a flat
/// face, the faces are sewn into a closed shell, and the ones that lie in one plane are merged back into a
/// single face (a box comes out with six faces, not twelve triangles). Units are taken as millimetres.
SKHandle sk_import_stl(const char *data, size_t size, const char *featureId) {
  SK_TRY
  const std::string feat = featureOrDefault(featureId, "import");
  if (!data || size == 0) {
    setError("the STL file is empty");
    return 0;
  }
  std::istringstream in(std::string(data, size));
  const occ::handle<Poly_Triangulation> mesh = RWStl::ReadStream(in);
  if (mesh.IsNull() || mesh->NbTriangles() == 0) {
    setError("this isn't an STL file SimplMaker can read");
    return 0;
  }
  // Sewing every triangle takes about a quarter of a millisecond, and the shape is slow to work with after.
  if (mesh->NbTriangles() > SK_STL_MAX_TRIANGLES) {
    setError("the mesh is too detailed (" + std::to_string(mesh->NbTriangles()) + " triangles, the limit is " +
             std::to_string(SK_STL_MAX_TRIANGLES) + "); reduce it to fewer triangles first");
    return 0;
  }

  Bnd_Box box;
  for (int i = 1; i <= mesh->NbNodes(); ++i) box.Add(mesh->Node(i));
  const double diagonal = std::sqrt(box.SquareExtent());
  const double tol = std::max(diagonal * 1e-6, 1e-6);

  BRepBuilderAPI_Sewing sew(tol);
  int added = 0;
  for (int t = 1; t <= mesh->NbTriangles(); ++t) {
    int a, b, c;
    mesh->Triangle(t).Get(a, b, c);
    const gp_Pnt p1 = mesh->Node(a), p2 = mesh->Node(b), p3 = mesh->Node(c);
    if (p1.Distance(p2) < tol || p2.Distance(p3) < tol || p3.Distance(p1) < tol) continue;  // a sliver
    BRepBuilderAPI_MakePolygon poly(p1, p2, p3, true);
    if (!poly.IsDone()) continue;
    BRepBuilderAPI_MakeFace face(poly.Wire(), true);
    if (!face.IsDone()) continue;
    sew.Add(face.Face());
    ++added;
  }
  sew.Perform();

  std::vector<TopoDS_Shape> solids;
  for (TopExp_Explorer ex(sew.SewedShape(), TopAbs_SHELL); ex.More(); ex.Next()) {
    const TopoDS_Shell &shell = TopoDS::Shell(ex.Current());
    if (!BRep_Tool::IsClosed(shell)) continue;
    BRepBuilderAPI_MakeSolid mk(shell);
    if (!mk.IsDone()) continue;
    TopoDS_Solid solid = mk.Solid();
    BRepLib::OrientClosedSolid(solid);
    // Merge the coplanar triangles. Float coordinates leave their planes a hair apart, so be generous.
    ShapeUpgrade_UnifySameDomain unify(solid, true, true, false);
    unify.SetLinearTolerance(std::max(diagonal * 1e-5, 1e-5));
    unify.SetAngularTolerance(1e-4);
    unify.Build();
    solids.push_back(unify.Shape());
  }
  if (solids.empty()) {
    setError(added == 0 ? "the STL file has no usable triangles"
                         : "the mesh has holes or gaps, so it doesn't enclose a solid (it must be watertight)");
    return 0;
  }
  return storeImported(solids, feat);
  SK_CATCH(0)
}

/// Reads an STL file (binary or ASCII) as a welded triangle mesh, ready for simplifying.
static bool readWeldedMesh(const char *data, size_t size, simpl::TriMesh &out) {
  std::istringstream in(std::string(data, size));
  // The merge angle is the widest there is: the reader would otherwise keep two copies of a corner on a sharp edge.
  const occ::handle<Poly_Triangulation> mesh = RWStl::ReadStream(in, M_PI);
  if (mesh.IsNull() || mesh->NbTriangles() == 0) {
    setError("this isn't an STL file SimplMaker can read");
    return false;
  }
  Bnd_Box box;
  out.points.reserve(mesh->NbNodes());
  for (int i = 1; i <= mesh->NbNodes(); ++i) {
    const gp_Pnt p = mesh->Node(i);
    box.Add(p);
    out.points.push_back({p.X(), p.Y(), p.Z()});
  }
  out.triangles.reserve(mesh->NbTriangles());
  for (int t = 1; t <= mesh->NbTriangles(); ++t) {
    int a, b, c;
    mesh->Triangle(t).Get(a, b, c);
    out.triangles.push_back({a - 1, b - 1, c - 1});
  }
  simpl::weld(out, std::max(std::sqrt(box.SquareExtent()) * 1e-6, 1e-6));  // as close as the importer sews
  return true;
}

long sk_stl_triangle_count(const char *data, size_t size) {
  SK_TRY
  if (!data || size == 0) return -1;
  if (size >= 84) {  // binary STL: the count is at byte 80 and the length has to match
    uint32_t n;
    std::memcpy(&n, data + 80, 4);
    if (size == 84 + 50 * size_t(n)) return long(n);
  }
  std::istringstream in(std::string(data, size));
  const occ::handle<Poly_Triangulation> mesh = RWStl::ReadStream(in);
  return mesh.IsNull() ? -1 : long(mesh->NbTriangles());
  SK_CATCH(-1)
}

static std::atomic<double> g_simplifyProgress{0};

double sk_stl_simplify_progress(void) { return g_simplifyProgress.load(); }

char *sk_stl_simplify(const char *data, size_t size, int target, size_t *outSize) {
  SK_TRY
  if (outSize) *outSize = 0;
  if (!data || size == 0) {
    setError("the STL file is empty");
    return nullptr;
  }
  simpl::TriMesh mesh;
  if (!readWeldedMesh(data, size, mesh)) return nullptr;
  g_simplifyProgress.store(0);
  simpl::simplify(mesh, size_t(std::max(target, 1)), &g_simplifyProgress);
  simpl::fillHoles(mesh);  // a mesh that is nearly closed becomes closed, so it can be made a solid

  const size_t n = mesh.triangles.size();
  const size_t bytes = 84 + 50 * n;
  char *out = static_cast<char *>(std::calloc(bytes, 1));
  if (!out) {
    setError("out of memory");
    return nullptr;
  }
  std::memcpy(out, "SimplMaker reduced mesh", 23);
  const uint32_t count = uint32_t(n);
  std::memcpy(out + 80, &count, 4);
  char *at = out + 84;
  for (const auto &t : mesh.triangles) {
    const auto &a = mesh.points[t[0]], &b = mesh.points[t[1]], &c = mesh.points[t[2]];
    const gp_Vec normal = gp_Vec(gp_Pnt(a[0], a[1], a[2]), gp_Pnt(b[0], b[1], b[2]))
                              .Crossed(gp_Vec(gp_Pnt(a[0], a[1], a[2]), gp_Pnt(c[0], c[1], c[2])));
    float f[12] = {0, 0, 0, float(a[0]), float(a[1]), float(a[2]), float(b[0]), float(b[1]), float(b[2]),
                   float(c[0]), float(c[1]), float(c[2])};
    if (normal.Magnitude() > 1e-300) {
      f[0] = float(normal.X() / normal.Magnitude());
      f[1] = float(normal.Y() / normal.Magnitude());
      f[2] = float(normal.Z() / normal.Magnitude());
    }
    std::memcpy(at, f, 48);
    at += 50;
  }
  if (outSize) *outSize = bytes;
  return out;
  SK_CATCH(nullptr)
}

void sk_buffer_free(char *buffer) { std::free(buffer); }

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
