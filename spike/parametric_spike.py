"""
Feasibility spike for SimplCAD (throwaway, NOT the product).

Proves the risky core of the plan end-to-end using OpenCASCADE (via the
`cadquery-ocp` Python bindings, so it runs anywhere incl. macOS):

  1. Parameters with expressions          (width, depth, height, hole_d ...)
  2. A 2D constraint solver                (tiny Levenberg-Marquardt, numpy)
  3. Profile/region detection              (split a plane by the sketch curves)
  4. Extrude with persistent face naming   (names derived from sketch curve IDs)
  5. Sketch on a face of the previous body (resolved by persistent name)
  6. Cut-extrude + name propagation through the boolean
  7. Edit a parameter -> full regeneration -> references still resolve
  8. Tessellation for rendering            (triangles per face, for picking)

Run:  pip install cadquery-ocp numpy && python3 spike/parametric_spike.py
"""
import math, time
import numpy as np

from OCP.gp import gp_Pnt, gp_Dir, gp_Ax2, gp_Ax3, gp_Vec, gp_Circ, gp_Pln
from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeEdge, BRepBuilderAPI_MakeFace
from OCP.BRepAlgoAPI import BRepAlgoAPI_Splitter, BRepAlgoAPI_Cut
from OCP.BRepPrimAPI import BRepPrimAPI_MakePrism
from OCP.BRepGProp import BRepGProp
from OCP.GProp import GProp_GProps
from OCP.BRepAdaptor import BRepAdaptor_Surface
from OCP.GeomAbs import GeomAbs_Plane
from OCP.TopAbs import TopAbs_FACE, TopAbs_EDGE, TopAbs_REVERSED
from OCP.TopExp import TopExp_Explorer
from OCP.collections import List_TopoDS_Shape as TopTools_ListOfShape
from OCP.TopoDS import TopoDS
from OCP.BRepMesh import BRepMesh_IncrementalMesh
from OCP.BRep import BRep_Tool
from OCP.TopLoc import TopLoc_Location


# --------------------------------------------------------------------------
# 1. Parameters: named expressions, evaluated in dependency order
# --------------------------------------------------------------------------
def eval_params(defs):
    """defs: name -> expression string. Resolves dependencies, detects cycles."""
    values, visiting = {}, set()

    def ev(name):
        if name in values:
            return values[name]
        if name in visiting:
            raise ValueError(f"cyclic parameter: {name}")
        visiting.add(name)
        expr = defs[name]
        deps = {n: ev(n) for n in defs if n != name and n in expr}
        values[name] = float(eval(expr, {"__builtins__": {}, "pi": math.pi}, deps))
        return values[name]

    for n in defs:
        ev(n)
    return values


# --------------------------------------------------------------------------
# 2. Sketch + constraint solver
#    Variables: point coords + circle radii. Lines reference point IDs, so
#    coincidence at shared corners is structural (no constraint needed).
# --------------------------------------------------------------------------
class Sketch:
    def __init__(self):
        self.points, self.lines, self.circles, self.cons = {}, {}, {}, []

    def point(self, pid, x, y): self.points[pid] = [x, y]
    def line(self, lid, a, b): self.lines[lid] = (a, b)
    def circle(self, cid, center, r): self.circles[cid] = [center, r]
    def add(self, *c): self.cons.append(c)

    # --- pack / unpack solver vector ---
    def _pack(self):
        self._pids = sorted(self.points); self._cids = sorted(self.circles)
        return np.array([v for p in self._pids for v in self.points[p]] +
                        [self.circles[c][1] for c in self._cids], float)

    def _unpack(self, x):
        for i, p in enumerate(self._pids):
            self.points[p] = [x[2 * i], x[2 * i + 1]]
        o = 2 * len(self._pids)
        for i, c in enumerate(self._cids):
            self.circles[c][1] = x[o + i]

    def _residuals(self, x):
        self._unpack(x); P = self.points; r = []
        for c in self.cons:
            kind = c[0]
            if kind == "fix":        _, p, X, Y = c; r += [P[p][0] - X, P[p][1] - Y]
            elif kind == "horizontal": a, b = self.lines[c[1]]; r.append(P[a][1] - P[b][1])
            elif kind == "vertical":   a, b = self.lines[c[1]]; r.append(P[a][0] - P[b][0])
            elif kind == "distance":
                _, a, b, d = c; r.append(math.dist(P[a], P[b]) - d)
            elif kind == "radius":   _, cid, d = c; r.append(self.circles[cid][1] - d)
            elif kind == "dx":       _, a, b, d = c; r.append(P[b][0] - P[a][0] - d)
            elif kind == "dy":       _, a, b, d = c; r.append(P[b][1] - P[a][1] - d)
        return np.array(r)

    def solve(self, tol=1e-10, iters=100):
        """Levenberg-Marquardt with a finite-difference Jacobian."""
        x = self._pack(); lam = 1e-3
        for it in range(iters):
            f = self._residuals(x); err = f @ f
            if err < tol: break
            J = np.empty((len(f), len(x))); h = 1e-7
            for j in range(len(x)):
                xp = x.copy(); xp[j] += h
                J[:, j] = (self._residuals(xp) - f) / h
            A = J.T @ J; g = J.T @ f
            while True:
                step = np.linalg.solve(A + lam * np.diag(np.diag(A) + 1e-9), -g)
                fn = self._residuals(x + step)
                if fn @ fn < err: x = x + step; lam *= 0.3; break
                lam *= 10
                if lam > 1e12: break
        self._unpack(x)
        J = np.empty((len(f), len(x)))
        for j in range(len(x)):
            xp = x.copy(); xp[j] += 1e-7
            J[:, j] = (self._residuals(xp) - self._residuals(x)) / 1e-7
        dof = len(x) - np.linalg.matrix_rank(J, tol=1e-6)
        self._unpack(x)
        return {"iterations": it, "residual": float(self._residuals(x) @ self._residuals(x)), "dof": int(dof)}


# --------------------------------------------------------------------------
# 3. Sketch -> OCCT edges -> regions (profiles)
# --------------------------------------------------------------------------
def sketch_edges(sk, frame: gp_Ax3):
    """Map every sketch curve to a 3D OCCT edge on the sketch plane. Returns {curveId: edge}."""
    o, xd, yd = frame.Location(), frame.XDirection(), frame.YDirection()
    to3d = lambda u, v: gp_Pnt(o.X() + u * xd.X() + v * yd.X(),
                               o.Y() + u * xd.Y() + v * yd.Y(),
                               o.Z() + u * xd.Z() + v * yd.Z())
    edges = {}
    for lid, (a, b) in sk.lines.items():
        edges[lid] = BRepBuilderAPI_MakeEdge(to3d(*sk.points[a]), to3d(*sk.points[b])).Edge()
    for cid, (c, r) in sk.circles.items():
        ax = gp_Ax2(to3d(*sk.points[c]), frame.Direction(), xd)
        edges[cid] = BRepBuilderAPI_MakeEdge(gp_Circ(ax, r)).Edge()
    return edges


def iter_shapes(shape, kind):
    ex = TopExp_Explorer(shape, kind)
    while ex.More():
        yield ex.Current(); ex.Next()


def find_regions(edges, frame):
    """Split a big planar face by the sketch edges; every resulting face is a region.
    Returns ([(face, set_of_bounding_curveIds)], owner_of) -- the curve IDs make profiles
    addressable, and owner_of(edge) maps any region edge back to the sketch curve it came from
    (exact, via the splitter's history -- no geometric guessing)."""
    base = BRepBuilderAPI_MakeFace(gp_Pln(frame), -1e4, 1e4, -1e4, 1e4).Face()
    sp = BRepAlgoAPI_Splitter()
    args, tools = TopTools_ListOfShape(), TopTools_ListOfShape()
    args.Append(base)
    for e in edges.values(): tools.Append(e)
    sp.SetArguments(args); sp.SetTools(tools); sp.Build()
    assert sp.IsDone()

    # origin map: split edge piece -> sketch curve id
    piece_owner = []
    for cid, e in edges.items():
        pieces = list(sp.Modified(e)) or [e]
        for p in pieces: piece_owner.append((p, cid))

    regions = []
    for f in iter_shapes(sp.Shape(), TopAbs_FACE):
        owners, touches_outside = set(), False
        for e in iter_shapes(f, TopAbs_EDGE):
            hit = [cid for p, cid in piece_owner if e.IsSame(p)]
            owners.update(hit)
            touches_outside |= not hit
        if not touches_outside:  # faces reaching the big base boundary are "outside"
            regions.append((TopoDS.Face(f), owners))

    def owner_of(edge):
        return next(cid for p, cid in piece_owner if edge.IsSame(p))
    return regions, owner_of


# --------------------------------------------------------------------------
# 4-6. Features with persistent naming
# --------------------------------------------------------------------------
class NamedShape:
    """A solid plus a map persistentName -> face (the topological-naming layer)."""
    def __init__(self, shape, names): self.shape, self.names = shape, names
    def face(self, name):
        if name not in self.names: raise KeyError(f"reference lost: {name}")
        return TopoDS.Face(self.names[name])


def extrude(feature_id, region_face, owners_by_edge, distance, direction):
    prism = BRepPrimAPI_MakePrism(region_face, gp_Vec(direction.XYZ()).Multiplied(distance))
    prism.Build()
    names = {f"{feature_id}.start": prism.FirstShape(), f"{feature_id}.end": prism.LastShape()}
    for e in iter_shapes(region_face, TopAbs_EDGE):
        cid = owners_by_edge(e)
        for side in prism.Generated(e):
            names[f"{feature_id}.side.{cid}"] = side
    return prism.Shape(), names


def propagate(op, prev_names, tool_names):
    """Carry names through a boolean using OCCT's Modified/IsDeleted history."""
    out = {}
    for src in (prev_names, tool_names):
        for n, f in src.items():
            if op.IsDeleted(f): continue
            mod = list(op.Modified(f))
            out[n] = mod[0] if mod else f   # a split face keeps the name on its first piece (MVP rule)
    return out


def face_frame(face):
    s = BRepAdaptor_Surface(face)
    assert s.GetType() == GeomAbs_Plane, "can only sketch on planar faces"
    pos = s.Plane().Position()
    if face.Orientation() == TopAbs_REVERSED:  # reversed face -> flip so the normal points outwards
        pos = gp_Ax3(pos.Location(), pos.Direction().Reversed(), pos.XDirection())
    return pos


# --------------------------------------------------------------------------
# The "document": parameters + feature list. regenerate() replays it.
# --------------------------------------------------------------------------
def regenerate(param_defs):
    P = eval_params(param_defs)

    # Sketch1 on XY: rectangle + centered hole
    sk1 = Sketch()
    for pid, (x, y) in {"p0": (0, 0), "p1": (10, 1), "p2": (9, 8), "p3": (-1, 7), "pc": (3, 3)}.items():
        sk1.point(pid, x, y)  # deliberately sloppy initial positions; the solver fixes them
    sk1.line("L0", "p0", "p1"); sk1.line("L1", "p1", "p2"); sk1.line("L2", "p2", "p3"); sk1.line("L3", "p3", "p0")
    sk1.circle("C0", "pc", 1.0)
    sk1.add("fix", "p0", 0, 0)
    sk1.add("horizontal", "L0"); sk1.add("horizontal", "L2")
    sk1.add("vertical", "L1"); sk1.add("vertical", "L3")
    sk1.add("distance", "p0", "p1", P["width"]); sk1.add("distance", "p1", "p2", P["depth"])
    sk1.add("radius", "C0", P["hole_d"] / 2)
    sk1.add("dx", "p0", "pc", P["width"] / 2); sk1.add("dy", "p0", "pc", P["depth"] / 2)
    s1 = sk1.solve()

    xy = gp_Ax3(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1), gp_Dir(1, 0, 0))
    e1 = sketch_edges(sk1, xy)
    regions, owner_of = find_regions(e1, xy)
    # Profile reference = "the region bounded by L0..L3 and C0" (stable across edits)
    profile = next(f for f, own in regions if own == {"L0", "L1", "L2", "L3", "C0"})

    body, names = extrude("E1", profile, owner_of, P["height"], gp_Dir(0, 0, 1))

    # Sketch2 on the persistent face "E1.end" (the top cap), cut a through-hole
    top = NamedShape(body, names).face("E1.end")
    frame = face_frame(top)
    sk2 = Sketch()
    sk2.point("q0", 0, 0)
    sk2.circle("C1", "q0", 2.0)
    sk2.add("radius", "C1", P["pin_d"] / 2)
    sk2.add("fix", "q0", P["width"] * 0.2, P["depth"] * 0.5)  # frame origin is the sketch-1 origin lifted
    s2 = sk2.solve()
    e2 = sketch_edges(sk2, frame)
    r2, owner2 = find_regions(e2, frame)
    disk = next(f for f, own in r2 if own == {"C1"})
    tool, tnames = extrude("E2", disk, owner2, P["height"] * 2, frame.Direction().Reversed())
    cut = BRepAlgoAPI_Cut(body, tool); cut.Build(); assert cut.IsDone()
    names = propagate(cut, names, {k: v for k, v in tnames.items() if ".side." in k})
    return NamedShape(cut.Shape(), names), P, (s1, s2)


def volume(shape):
    p = GProp_GProps(); BRepGProp.VolumeProperties_s(shape, p); return p.Mass()


def tessellate(shape, deflection=0.05):
    BRepMesh_IncrementalMesh(shape, deflection, False, 0.3, True)
    per_face = []
    for f in iter_shapes(shape, TopAbs_FACE):
        tri = BRep_Tool.Triangulation_s(TopoDS.Face(f), TopLoc_Location())
        per_face.append(tri.NbTriangles() if tri else 0)
    return per_face


def report(label, param_defs):
    t0 = time.perf_counter()
    model, P, (s1, s2) = regenerate(param_defs)
    t_regen = time.perf_counter() - t0
    tris = tessellate(model.shape)
    t_total = time.perf_counter() - t0
    expected = P["width"] * P["depth"] * P["height"] - math.pi * ((P["hole_d"] / 2) ** 2 + (P["pin_d"] / 2) ** 2) * P["height"]
    v = volume(model.shape)
    print(f"\n=== {label} ===")
    print(f"params: { {k: round(x, 3) for k, x in P.items()} }")
    print(f"sketch1 solve: {s1}   sketch2 solve: {s2}")
    print(f"volume  {v:10.3f}   expected {expected:10.3f}   {'OK' if abs(v - expected) < 1e-3 * expected else 'MISMATCH'}")
    top_z = BRepAdaptor_Surface(model.face("E1.end")).Plane().Location().Z()
    print(f"persistent 'E1.end' resolves to plane z={top_z:.3f} (height={P['height']})")
    print(f"named faces: {sorted(model.names)}")
    print(f"faces={len(tris)} triangles={sum(tris)}  regen={t_regen*1000:.1f} ms  +mesh={t_total*1000:.1f} ms")
    return v, expected


if __name__ == "__main__":
    params = {"width": "60", "depth": "40", "height": "10", "hole_d": "depth / 4", "pin_d": "6"}
    report("initial model", params)
    # The parametric edit: change values; hole_d follows depth via its expression
    params.update(width="90", depth="50", height="25")
    report("after editing width/depth/height", params)
    try:
        eval_params({"a": "b + 1", "b": "a * 2"})
    except ValueError as e:
        print(f"\ncycle detection: {e}")
