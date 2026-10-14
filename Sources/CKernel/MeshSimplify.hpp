// Reduces a closed triangle mesh to fewer triangles by collapsing edges in order of quadric error
// (Garland & Heckbert, "Surface Simplification Using Quadric Error Metrics"). Flat areas cost nothing to
// merge, so they go first; a sharp edge or a corner holds because moving it would be expensive.
//
// Pure C++, no OpenCASCADE: SimplKernel.cpp reads the STL and calls this.
//
// Copyright © 2026 Atle Mo. All rights reserved.
#ifndef SIMPL_MESH_SIMPLIFY_HPP
#define SIMPL_MESH_SIMPLIFY_HPP

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <iterator>
#include <queue>
#include <unordered_set>
#include <unordered_map>
#include <vector>

namespace simpl {

struct TriMesh {
  std::vector<std::array<double, 3>> points;
  std::vector<std::array<int, 3>> triangles;
};

namespace detail {

using Vec = std::array<double, 3>;

inline Vec sub(const Vec &a, const Vec &b) { return {a[0] - b[0], a[1] - b[1], a[2] - b[2]}; }
inline Vec cross(const Vec &a, const Vec &b) {
  return {a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]};
}
inline double dot(const Vec &a, const Vec &b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
inline double length(const Vec &a) { return std::sqrt(dot(a, a)); }

/// A symmetric 4×4 matrix, the squared distance to a set of planes: error(p) = (p,1)ᵀ Q (p,1).
/// Stored as aa ab ac ad bb bc bd cc cd dd.
struct Quadric {
  std::array<double, 10> q{};

  void addPlane(const Vec &n, double d, double weight) {
    const double a = n[0], b = n[1], c = n[2];
    q[0] += weight * a * a;
    q[1] += weight * a * b;
    q[2] += weight * a * c;
    q[3] += weight * a * d;
    q[4] += weight * b * b;
    q[5] += weight * b * c;
    q[6] += weight * b * d;
    q[7] += weight * c * c;
    q[8] += weight * c * d;
    q[9] += weight * d * d;
  }
  Quadric operator+(const Quadric &o) const {
    Quadric r;
    for (int i = 0; i < 10; ++i) r.q[i] = q[i] + o.q[i];
    return r;
  }
  double error(const Vec &p) const {
    const double x = p[0], y = p[1], z = p[2];
    return q[0] * x * x + 2 * q[1] * x * y + 2 * q[2] * x * z + 2 * q[3] * x + q[4] * y * y + 2 * q[5] * y * z +
           2 * q[6] * y + q[7] * z * z + 2 * q[8] * z + q[9];
  }
  /// The point of least error, if the three planes' normals pin one down.
  bool optimum(Vec &out) const {
    const double a = q[0], b = q[1], c = q[2], e = q[4], f = q[5], i = q[7];
    const double det = a * (e * i - f * f) - b * (b * i - f * c) + c * (b * f - e * c);
    const double scale = (a + e + i) / 3;
    if (!(std::abs(det) > 1e-8 * scale * scale * scale)) return false;
    const double r0 = -q[3], r1 = -q[6], r2 = -q[8];
    out[0] = (r0 * (e * i - f * f) - b * (r1 * i - f * r2) + c * (r1 * f - e * r2)) / det;
    out[1] = (a * (r1 * i - f * r2) - r0 * (b * i - f * c) + c * (b * r2 - r1 * c)) / det;
    out[2] = (a * (e * r2 - r1 * f) - b * (b * r2 - r1 * c) + r0 * (b * f - e * c)) / det;
    return std::isfinite(out[0]) && std::isfinite(out[1]) && std::isfinite(out[2]);
  }
};

/// How well shaped a triangle is: its height over its longest side (0 for a line, 0.87 for an equilateral).
inline double shape(const Vec &a, const Vec &b, const Vec &c) {
  const double longest = std::max({length(sub(b, a)), length(sub(c, b)), length(sub(a, c))});
  if (longest <= 0) return 0;
  return length(cross(sub(b, a), sub(c, a))) / (longest * longest);
}

}  // namespace detail

/// Joins the points that lie within `tolerance` of each other (an STL file lists every corner once per
/// triangle, and the copies can differ in their last digits) and drops the triangles that have collapsed
/// to a line or a point.
inline void weld(TriMesh &mesh, double tolerance) {
  struct Key {
    int64_t x, y, z;
    bool operator==(const Key &o) const { return x == o.x && y == o.y && z == o.z; }
  };
  struct KeyHash {
    size_t operator()(const Key &k) const {
      return size_t(k.x * 73856093LL) ^ size_t(k.y * 19349663LL) ^ size_t(k.z * 83492791LL);
    }
  };
  // Cells as wide as the tolerance: a point's twin is in its own cell or one next to it.
  std::unordered_map<Key, std::vector<int>, KeyHash> cells;
  std::vector<int> remap(mesh.points.size());
  std::vector<std::array<double, 3>> kept;
  for (size_t i = 0; i < mesh.points.size(); ++i) {
    const auto &p = mesh.points[i];
    const Key home{int64_t(std::floor(p[0] / tolerance)), int64_t(std::floor(p[1] / tolerance)),
                   int64_t(std::floor(p[2] / tolerance))};
    int found = -1;
    for (int dx = -1; dx <= 1 && found < 0; ++dx)
      for (int dy = -1; dy <= 1 && found < 0; ++dy)
        for (int dz = -1; dz <= 1 && found < 0; ++dz) {
          const auto it = cells.find({home.x + dx, home.y + dy, home.z + dz});
          if (it == cells.end()) continue;
          for (int k : it->second) {
            const auto &q = kept[k];
            if (std::abs(q[0] - p[0]) <= tolerance && std::abs(q[1] - p[1]) <= tolerance && std::abs(q[2] - p[2]) <= tolerance) {
              found = k;
              break;
            }
          }
        }
    if (found < 0) {
      found = int(kept.size());
      kept.push_back(p);
      cells[home].push_back(found);
    }
    remap[i] = found;
  }
  std::vector<std::array<int, 3>> tris;
  tris.reserve(mesh.triangles.size());
  for (const auto &t : mesh.triangles) {
    const std::array<int, 3> n{remap[t[0]], remap[t[1]], remap[t[2]]};
    if (n[0] != n[1] && n[1] != n[2] && n[2] != n[0]) tris.push_back(n);
  }
  mesh.points = std::move(kept);
  mesh.triangles = std::move(tris);
}

/// Collapses edges until about `target` triangles are left (or no edge can be collapsed without
/// folding the surface over or breaking its closed shape). The mesh must already be welded. Each
/// collapse removes two triangles from a closed mesh and keeps it closed.
inline void simplify(TriMesh &mesh, size_t target, std::atomic<double> *progress = nullptr) {
  using namespace detail;
  target = std::max<size_t>(target, 8);
  if (mesh.triangles.size() <= target) return;

  // Work in a unit-sized box: the thresholds below are relative to the model's size.
  Vec lo = mesh.points.front(), hi = lo;
  for (const auto &p : mesh.points)
    for (int k = 0; k < 3; ++k) {
      lo[k] = std::min(lo[k], p[k]);
      hi[k] = std::max(hi[k], p[k]);
    }
  const double diagonal = length(sub(hi, lo));
  if (!(diagonal > 0)) return;
  const Vec centre{(lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2};
  std::vector<Vec> pos(mesh.points.size());
  for (size_t i = 0; i < pos.size(); ++i)
    for (int k = 0; k < 3; ++k) pos[i][k] = (mesh.points[i][k] - centre[k]) / diagonal;

  std::vector<std::array<int, 3>> tri = mesh.triangles;
  std::vector<char> triAlive(tri.size(), 1);
  std::vector<char> vertAlive(pos.size(), 1);
  std::vector<std::vector<int>> vertTris(pos.size());
  std::vector<Quadric> quadric(pos.size());
  std::vector<unsigned> version(pos.size(), 0);
  for (size_t t = 0; t < tri.size(); ++t) {
    const auto &T = tri[t];
    for (int k = 0; k < 3; ++k) vertTris[T[k]].push_back(int(t));
    Vec n = cross(sub(pos[T[1]], pos[T[0]]), sub(pos[T[2]], pos[T[0]]));
    const double twiceArea = length(n);
    if (twiceArea <= 0) continue;
    for (double &c : n) c /= twiceArea;
    const double d = -dot(n, pos[T[0]]);
    for (int k = 0; k < 3; ++k) quadric[T[k]].addPlane(n, d, twiceArea / 2);
  }
  size_t alive = tri.size();
  const size_t start = alive;
  if (progress) progress->store(0);

  const double shortest = 1e-5;  // no side shorter than this (of the model's diagonal): a sliver would not survive sewing
  const double thinnest = 1e-4;  // nor a triangle thinner than this (see `shape`)

  auto neighbours = [&](int v, std::vector<int> &out) {
    out.clear();
    for (int t : vertTris[v]) {
      if (!triAlive[t]) continue;
      for (int w : tri[t])
        if (w != v) out.push_back(w);
    }
    std::sort(out.begin(), out.end());
    out.erase(std::unique(out.begin(), out.end()), out.end());
  };

  // Whether collapsing the edge u–v keeps the mesh a closed surface: the two share exactly the two corners
  // opposite the edge, and the edge has exactly two triangles.
  std::vector<int> nu, nv, common;
  auto collapsible = [&](int u, int v) {
    int shared = 0;
    for (int t : vertTris[u])
      if (triAlive[t] && (tri[t][0] == v || tri[t][1] == v || tri[t][2] == v)) ++shared;
    if (shared != 2) return false;
    neighbours(u, nu);
    neighbours(v, nv);
    common.clear();
    std::set_intersection(nu.begin(), nu.end(), nv.begin(), nv.end(), std::back_inserter(common));
    return common.size() == 2;
  };

  // Whether putting u and v at p leaves their other triangles facing as they did and well shaped.
  auto movable = [&](int u, int v, const Vec &p) {
    for (int side = 0; side < 2; ++side) {
      const int from = side == 0 ? u : v;
      for (int t : vertTris[from]) {
        if (!triAlive[t]) continue;
        const auto &T = tri[t];
        if ((T[0] == u || T[1] == u || T[2] == u) && (T[0] == v || T[1] == v || T[2] == v)) continue;  // goes away
        Vec before[3], after[3];
        for (int k = 0; k < 3; ++k) {
          before[k] = pos[T[k]];
          after[k] = (T[k] == u || T[k] == v) ? p : pos[T[k]];
        }
        const Vec n0 = cross(sub(before[1], before[0]), sub(before[2], before[0]));
        const Vec n1 = cross(sub(after[1], after[0]), sub(after[2], after[0]));
        const double l0 = length(n0), l1 = length(n1);
        if (l1 <= 0) return false;
        if (l0 > 0 && dot(n0, n1) / (l0 * l1) < 0.2) return false;  // folded over, or turned too far
        if (length(sub(after[1], after[0])) < shortest || length(sub(after[2], after[1])) < shortest ||
            length(sub(after[0], after[2])) < shortest)
          return false;
        const double s1 = shape(after[0], after[1], after[2]);
        if (s1 < thinnest && s1 < shape(before[0], before[1], before[2])) return false;
      }
    }
    return true;
  };

  struct Candidate {
    double cost;
    int u, v;
    unsigned vu, vv;
    Vec p;
    bool operator<(const Candidate &o) const { return cost > o.cost; }  // a min-heap
  };
  std::priority_queue<Candidate> heap;

  // Where the edge u–v would best collapse to, and what that costs. False if it can't be collapsed at all.
  auto plan = [&](int u, int v, Candidate &out) {
    if (!collapsible(u, v)) return false;
    const Quadric q = quadric[u] + quadric[v];
    const Vec mid{(pos[u][0] + pos[v][0]) / 2, (pos[u][1] + pos[v][1]) / 2, (pos[u][2] + pos[v][2]) / 2};
    std::vector<std::pair<double, Vec>> options;
    Vec best;
    if (q.optimum(best)) {
      const double reach = length(sub(pos[u], pos[v]));
      if (length(sub(best, mid)) <= reach) options.push_back({q.error(best), best});  // not flung off far from the edge
    }
    options.push_back({q.error(mid), mid});
    options.push_back({q.error(pos[u]), pos[u]});
    options.push_back({q.error(pos[v]), pos[v]});
    std::sort(options.begin(), options.end(), [](const auto &a, const auto &b) { return a.first < b.first; });
    for (const auto &o : options) {
      if (!movable(u, v, o.second)) continue;
      // Among edges that cost nothing (all of a flat area) the short ones go first. Without this the flat
      // collapses pile up on a few vertices, whose lists of neighbours grow until every step is slow.
      const double edge = length(sub(pos[u], pos[v]));
      out = {std::max(o.first, 0.0) + 1e-9 * edge * edge, u, v, version[u], version[v], o.second};
      return true;
    }
    return false;
  };

  std::vector<int> around;
  auto offerEdgesOf = [&](int u) {
    neighbours(u, around);
    const std::vector<int> copy = around;
    for (int w : copy) {
      Candidate c;
      if (plan(std::min(u, w), std::max(u, w), c)) heap.push(c);
    }
  };
  for (size_t u = 0; u < pos.size(); ++u) {
    neighbours(int(u), around);
    for (int w : around) {
      if (w < int(u)) continue;
      Candidate c;
      if (plan(int(u), w, c)) heap.push(c);
    }
  }

  while (alive > target && !heap.empty()) {
    const Candidate c = heap.top();
    heap.pop();
    if (!vertAlive[c.u] || !vertAlive[c.v] || version[c.u] != c.vu || version[c.v] != c.vv) continue;  // out of date
    if (!collapsible(c.u, c.v) || !movable(c.u, c.v, c.p)) continue;  // the neighbourhood has changed since

    const int u = c.u, v = c.v;
    pos[u] = c.p;
    quadric[u] = quadric[u] + quadric[v];
    for (int t : vertTris[v]) {
      if (!triAlive[t]) continue;
      auto &T = tri[t];
      if (T[0] == u || T[1] == u || T[2] == u) {
        triAlive[t] = 0;
        --alive;
      } else {
        for (int &w : T)
          if (w == v) w = u;
        vertTris[u].push_back(t);
      }
    }
    vertTris[v].clear();
    vertAlive[v] = 0;
    ++version[u];
    // The triangles that went away are still listed under u; drop them now and then so the lists stay short.
    auto &mine = vertTris[u];
    mine.erase(std::remove_if(mine.begin(), mine.end(), [&](int t) { return !triAlive[t]; }), mine.end());
    offerEdgesOf(u);
    if (progress && (start - alive) % 512 < 2) progress->store(double(start - alive) / double(start - target));
  }
  if (progress) progress->store(1);

  // Write back only what is left.
  std::vector<int> renumber(pos.size(), -1);
  mesh.points.clear();
  mesh.triangles.clear();
  for (size_t t = 0; t < tri.size(); ++t) {
    if (!triAlive[t]) continue;
    std::array<int, 3> n;
    for (int k = 0; k < 3; ++k) {
      const int w = tri[t][k];
      if (renumber[w] < 0) {
        renumber[w] = int(mesh.points.size());
        mesh.points.push_back({pos[w][0] * diagonal + centre[0], pos[w][1] * diagonal + centre[1], pos[w][2] * diagonal + centre[2]});
      }
      n[k] = renumber[w];
    }
    mesh.triangles.push_back(n);
  }
}

/// Closes the small holes of a mesh (scanned and sculpted models often have a few). Every loop of edges that
/// has a triangle on one side only, and no more than `maxLoop` edges, is filled with a fan of triangles from
/// a new point in the middle of the loop. Returns how many holes were filled.
inline int fillHoles(TriMesh &mesh, size_t maxLoop = 256) {
  auto key = [](int a, int b) { return (uint64_t(uint32_t(a)) << 32) | uint32_t(b); };
  std::unordered_set<uint64_t> directed;
  directed.reserve(mesh.triangles.size() * 3);
  for (const auto &t : mesh.triangles)
    for (int k = 0; k < 3; ++k) directed.insert(key(t[k], t[(k + 1) % 3]));

  std::unordered_map<int, std::vector<int>> leaving;  // boundary edges a -> b, by a
  size_t free = 0;
  for (const auto &t : mesh.triangles)
    for (int k = 0; k < 3; ++k) {
      const int a = t[k], b = t[(k + 1) % 3];
      if (!directed.count(key(b, a))) {
        leaving[a].push_back(b);
        ++free;
      }
    }
  if (free == 0) return 0;

  int filled = 0;
  for (auto &entry : leaving) {
    while (!entry.second.empty()) {
      const int start = entry.first;
      std::vector<int> loop{start};
      int at = entry.second.back();
      entry.second.pop_back();
      bool closed = false;
      while (loop.size() <= maxLoop) {
        if (at == start) {
          closed = true;
          break;
        }
        loop.push_back(at);
        auto next = leaving.find(at);
        if (next == leaving.end() || next->second.empty()) break;
        at = next->second.back();
        next->second.pop_back();
      }
      if (!closed || loop.size() < 3) continue;
      // The loop runs along existing triangles, so the new ones go the other way round.
      const size_t n = loop.size();
      if (n == 3) {
        mesh.triangles.push_back({loop[0], loop[2], loop[1]});
      } else {
        detail::Vec c{0, 0, 0};
        for (int v : loop)
          for (int k = 0; k < 3; ++k) c[k] += mesh.points[v][k] / double(n);
        const int centre = int(mesh.points.size());
        mesh.points.push_back(c);
        for (size_t i = 0; i < n; ++i) mesh.triangles.push_back({loop[(i + 1) % n], loop[i], centre});
      }
      ++filled;
    }
  }
  return filled;
}

}  // namespace simpl

#endif
