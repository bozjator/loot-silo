// Loot Silo's 3D model renderer: a depth-buffer triangle rasterizer.
//
// The app (lib/core/model_raster.dart) hands it a mesh once, then asks for
// frames in three steps: ls_frame_begin sets up a camera, ls_frame_transform
// projects the vertices and ls_frame_band draws rows of the picture. The
// last two take "part i of n": the parts touch separate vertices and
// separate rows, so they may run on different threads at the same time
// (all transforms first, then all bands).
//
// The camera is orthographic and fits the mesh's bounding sphere to the
// picture. Every pixel keeps its nearest surface (no sorting), shaded from
// the vertex normals with one light fixed to the camera plus ambient light.
// Output is premultiplied RGBA on a transparent background, averaged down
// from `ss` × `ss` samples per pixel.
//
// Plain C99, no dependencies.

#include <float.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#define LS_EXPORT __declspec(dllexport)
#else
#define LS_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

#define LS_WIREFRAME 1
#define LS_GRID 2
#define LS_NO_TEXTURES 4

#define MAT_DOUBLE_SIDED 1
#define MAT_NEAREST 2

#define AMBIENT 0.42f
#define GRID_CELLS 10
#define GRID_LINES ((GRID_CELLS + 1) * 2)

// Mask values: the wireframe wins over the floor grid.
#define MASK_GRID 1
#define MASK_WIRE 2

typedef struct LsTexture {
  int32_t w, h;
  uint8_t* rgba;  // straight alpha
} LsTexture;

typedef struct LsMesh {
  int32_t n_verts, n_tris, n_mats;
  float* pos;
  float* nrm;
  float* uv;  // NULL without texture coordinates
  uint32_t* idx;
  uint16_t* tri_mat;
  uint32_t* mat_color;  // ARGB
  uint8_t* mat_flags;
  const LsTexture** mat_tex;
  uint32_t* translucent;  // triangles whose material isn't opaque
  int32_t n_translucent;
  int32_t flat_shaded;
  float cx, cy, cz, radius, floor_y;
} LsMesh;

typedef struct LsContext {
  const LsMesh* mesh;
  int32_t w, h, ss, W, H;
  uint32_t flags;
  uint32_t line_color;
  int32_t line_thick;
  float light[3];  // toward the light, in view space
  float rot[9];    // model → view
  float lm[3];     // the light in model space
  float scale, ox, oy;
  // Where the work is: sampled vertices per output row, summed up. Bands
  // are cut so that each has about the same share.
  double* row_work;  // h + 1 running totals
  int32_t cap_rows;
  // Projected vertices: sample x, y, depth (toward the viewer), n·light.
  float* sx;
  float* sy;
  float* sz;
  float* sd;
  int32_t cap_verts;
  float* zbuf;
  uint32_t* cbuf;  // premultiplied, bytes R G B A
  uint8_t* mask;
  size_t cap_px;
  float grid[GRID_LINES][6];
} LsContext;

// ---------------------------------------------------------------- setup --

LS_EXPORT LsTexture* ls_texture_create(const uint8_t* rgba, int32_t w,
                                       int32_t h) {
  if (w <= 0 || h <= 0 || w > 16384 || h > 16384) return NULL;
  LsTexture* t = (LsTexture*)malloc(sizeof(LsTexture));
  if (!t) return NULL;
  size_t n = (size_t)w * (size_t)h * 4;
  t->rgba = (uint8_t*)malloc(n);
  if (!t->rgba) {
    free(t);
    return NULL;
  }
  memcpy(t->rgba, rgba, n);
  t->w = w;
  t->h = h;
  return t;
}

LS_EXPORT void ls_texture_free(LsTexture* t) {
  if (!t) return;
  free(t->rgba);
  free(t);
}

LS_EXPORT void ls_mesh_free(LsMesh* m) {
  if (!m) return;
  free(m->pos);
  free(m->nrm);
  free(m->uv);
  free(m->idx);
  free(m->tri_mat);
  free(m->mat_color);
  free(m->mat_flags);
  free((void*)m->mat_tex);
  free(m->translucent);
  free(m);
}

static void* copy_of(const void* src, size_t bytes) {
  void* p = malloc(bytes ? bytes : 1);
  if (p && bytes) memcpy(p, src, bytes);
  return p;
}

// Copies the arrays. NULL when memory runs out or an index points outside
// the vertices or materials.
LS_EXPORT LsMesh* ls_mesh_create(const float* pos, const float* nrm,
                                 const float* uv, const uint32_t* idx,
                                 const uint16_t* tri_mat, int32_t n_verts,
                                 int32_t n_tris, const uint32_t* mat_color,
                                 const uint8_t* mat_flags, int32_t n_mats,
                                 int32_t has_uv, int32_t flat_shaded) {
  if (!has_uv) uv = NULL;
  if (n_verts <= 0 || n_tris <= 0 || n_mats <= 0) return NULL;
  for (int32_t i = 0; i < n_tris * 3; i++) {
    if (idx[i] >= (uint32_t)n_verts) return NULL;
  }
  int32_t n_translucent = 0;
  for (int32_t t = 0; t < n_tris; t++) {
    if (tri_mat[t] >= n_mats) return NULL;
    if ((mat_color[tri_mat[t]] >> 24) < 255) n_translucent++;
  }
  LsMesh* m = (LsMesh*)calloc(1, sizeof(LsMesh));
  if (!m) return NULL;
  m->n_verts = n_verts;
  m->n_tris = n_tris;
  m->n_mats = n_mats;
  m->flat_shaded = flat_shaded;
  m->pos = (float*)copy_of(pos, sizeof(float) * 3 * (size_t)n_verts);
  m->nrm = (float*)copy_of(nrm, sizeof(float) * 3 * (size_t)n_verts);
  m->uv = uv ? (float*)copy_of(uv, sizeof(float) * 2 * (size_t)n_verts) : NULL;
  m->idx = (uint32_t*)copy_of(idx, sizeof(uint32_t) * 3 * (size_t)n_tris);
  m->tri_mat = (uint16_t*)copy_of(tri_mat, sizeof(uint16_t) * (size_t)n_tris);
  m->mat_color = (uint32_t*)copy_of(mat_color, sizeof(uint32_t) * n_mats);
  m->mat_flags = (uint8_t*)copy_of(mat_flags, n_mats);
  m->mat_tex = (const LsTexture**)calloc(n_mats, sizeof(LsTexture*));
  m->translucent =
      (uint32_t*)malloc(sizeof(uint32_t) * (n_translucent ? n_translucent : 1));
  if (!m->pos || !m->nrm || (uv && !m->uv) || !m->idx || !m->tri_mat ||
      !m->mat_color || !m->mat_flags || !m->mat_tex || !m->translucent) {
    ls_mesh_free(m);
    return NULL;
  }
  for (int32_t t = 0; t < n_tris; t++) {
    if ((mat_color[tri_mat[t]] >> 24) < 255) {
      m->translucent[m->n_translucent++] = (uint32_t)t;
    }
  }
  float lo[3] = {FLT_MAX, FLT_MAX, FLT_MAX};
  float hi[3] = {-FLT_MAX, -FLT_MAX, -FLT_MAX};
  for (int32_t v = 0; v < n_verts; v++) {
    for (int k = 0; k < 3; k++) {
      float f = pos[v * 3 + k];
      if (f < lo[k]) lo[k] = f;
      if (f > hi[k]) hi[k] = f;
    }
  }
  double dx = (double)hi[0] - lo[0], dy = (double)hi[1] - lo[1],
         dz = (double)hi[2] - lo[2];
  m->cx = (lo[0] + hi[0]) / 2;
  m->cy = (lo[1] + hi[1]) / 2;
  m->cz = (lo[2] + hi[2]) / 2;
  double r = sqrt(dx * dx + dy * dy + dz * dz) / 2;
  m->radius = (float)(r > 1e-9 ? r : 1e-9);
  m->floor_y = lo[1] - m->cy;
  return m;
}

// The texture of one material (NULL for its plain colour). The mesh
// doesn't own it: keep it alive while the mesh may be drawn.
LS_EXPORT void ls_mesh_set_texture(LsMesh* m, int32_t material,
                                   const LsTexture* texture) {
  if (!m || material < 0 || material >= m->n_mats) return;
  m->mat_tex[material] = texture;
}

LS_EXPORT LsContext* ls_context_create(void) {
  return (LsContext*)calloc(1, sizeof(LsContext));
}

LS_EXPORT void ls_context_free(LsContext* c) {
  if (!c) return;
  free(c->sx);
  free(c->sy);
  free(c->sz);
  free(c->sd);
  free(c->zbuf);
  free(c->cbuf);
  free(c->mask);
  free(c->row_work);
  free(c);
}

// A picture's pixels outside any Dart heap, so worker isolates can fill it.
LS_EXPORT uint8_t* ls_buffer_alloc(int64_t bytes) {
  return bytes > 0 ? (uint8_t*)malloc((size_t)bytes) : NULL;
}

LS_EXPORT void ls_buffer_free(uint8_t* buffer) { free(buffer); }

// ---------------------------------------------------------------- frame --

// Sets up a frame of the mesh for a camera: `yaw` and `pitch` in radians,
// `zoom` 1 fits the model, `pan_x` / `pan_y` move it by output pixels. The
// picture is `w` × `h` pixels, each averaged from `ss` × `ss` samples.
// `line_argb` and `line_px` (a width in output pixels) draw the wireframe
// and the floor grid. Returns 0 when memory runs out.
LS_EXPORT int32_t ls_frame_begin(LsContext* c, const LsMesh* m, float yaw,
                                 float pitch, float zoom, float pan_x,
                                 float pan_y, int32_t w, int32_t h, int32_t ss,
                                 uint32_t flags, uint32_t line_argb,
                                 float line_px) {
  if (!c || !m || w <= 0 || h <= 0 || w > 16384 || h > 16384) return 0;
  if (ss < 1) ss = 1;
  if (ss > 4) ss = 4;
  c->mesh = NULL;
  if (m->n_verts > c->cap_verts) {
    free(c->sx);
    free(c->sy);
    free(c->sz);
    free(c->sd);
    size_t n = sizeof(float) * (size_t)m->n_verts;
    c->sx = (float*)malloc(n);
    c->sy = (float*)malloc(n);
    c->sz = (float*)malloc(n);
    c->sd = (float*)malloc(n);
    c->cap_verts = c->sx && c->sy && c->sz && c->sd ? m->n_verts : 0;
    if (!c->cap_verts) return 0;
  }
  size_t px = (size_t)w * ss * (size_t)h * ss;
  if (px > c->cap_px) {
    free(c->zbuf);
    free(c->cbuf);
    free(c->mask);
    c->zbuf = (float*)malloc(px * sizeof(float));
    c->cbuf = (uint32_t*)malloc(px * sizeof(uint32_t));
    c->mask = (uint8_t*)malloc(px);
    c->cap_px = c->zbuf && c->cbuf && c->mask ? px : 0;
    if (!c->cap_px) return 0;
  }
  if (h > c->cap_rows) {
    free(c->row_work);
    c->row_work = (double*)malloc(sizeof(double) * ((size_t)h + 1));
    c->cap_rows = c->row_work ? h : 0;
    if (!c->cap_rows) return 0;
  }
  c->w = w;
  c->h = h;
  c->ss = ss;
  c->W = w * ss;
  c->H = h * ss;
  c->flags = flags;
  c->line_color = line_argb;
  int thick = (int)lroundf(line_px * ss);
  c->line_thick = thick < 1 ? 1 : thick;

  // View space: x right, y up, z toward the viewer.
  const float cyw = cosf(yaw), syw = sinf(yaw);
  const float cp = cosf(pitch), sp = sinf(pitch);
  float* r = c->rot;
  r[0] = cyw;
  r[1] = 0;
  r[2] = syw;
  r[3] = syw * sp;
  r[4] = cp;
  r[5] = -cyw * sp;
  r[6] = -syw * cp;
  r[7] = sp;
  r[8] = cyw * cp;
  // Toward the light: above, a little left, in front.
  float lx = -0.35f, ly = 0.8f, lz = 0.55f;
  const float ll = sqrtf(lx * lx + ly * ly + lz * lz);
  lx /= ll;
  ly /= ll;
  lz /= ll;
  c->light[0] = lx;
  c->light[1] = ly;
  c->light[2] = lz;
  // The light in model space, so a vertex needs one dot product.
  c->lm[0] = r[0] * lx + r[3] * ly + r[6] * lz;
  c->lm[1] = r[1] * lx + r[4] * ly + r[7] * lz;
  c->lm[2] = r[2] * lx + r[5] * ly + r[8] * lz;

  const float shortest = (float)(w < h ? w : h);
  const float scale = shortest / (2 * m->radius) * 0.95f * zoom * ss;
  const float ox = (w / 2.0f + pan_x) * ss, oy = (h / 2.0f + pan_y) * ss;
  c->scale = scale;
  c->ox = ox;
  c->oy = oy;

  // The rows of a sample of the vertices show where the triangles are.
  // Every row also costs its pixels, so none weighs nothing.
  double* work = c->row_work;
  for (int y = 0; y <= h; y++) work[y] = 0;
  const int32_t stride = m->n_verts / 65536 + 1;
  int32_t sampled = 0;
  for (int32_t v = 0; v < m->n_verts; v += stride) {
    const float x = m->pos[v * 3] - m->cx, y = m->pos[v * 3 + 1] - m->cy,
                z = m->pos[v * 3 + 2] - m->cz;
    const float row = (oy - (r[3] * x + r[4] * y + r[5] * z) * scale) / ss;
    if (row >= 0 && row < h) {
      work[(int)row + 1] += 1;
      sampled++;
    }
  }
  const double per_row = sampled > 0 ? 3.0 * h / sampled : 0;
  for (int y = 1; y <= h; y++) {
    work[y] = work[y - 1] + 1 + work[y] * per_row;
  }

  // A floor of 10 × 10 squares under the model, 1.5 radii around it.
  const float half = m->radius * 1.5f;
  const float fy = m->floor_y;
  for (int i = 0; i <= GRID_CELLS; i++) {
    const float at = -half + 2 * half * i / GRID_CELLS;
    const float ends[2][2][3] = {
        {{at, fy, -half}, {at, fy, half}},
        {{-half, fy, at}, {half, fy, at}},
    };
    for (int k = 0; k < 2; k++) {
      float* g = c->grid[i * 2 + k];
      for (int e = 0; e < 2; e++) {
        const float x = ends[k][e][0], y = ends[k][e][1], z = ends[k][e][2];
        g[e * 3] = ox + (r[0] * x + r[2] * z) * scale;
        g[e * 3 + 1] = oy - (r[3] * x + r[4] * y + r[5] * z) * scale;
        g[e * 3 + 2] = (r[6] * x + r[7] * y + r[8] * z) * scale;
      }
    }
  }
  c->mesh = m;
  return 1;
}

// Projects part `part` of `parts` of the frame's vertices. Every part must
// be done before any band is drawn.
LS_EXPORT void ls_frame_transform(LsContext* c, int32_t part, int32_t parts) {
  if (!c || !c->mesh || parts <= 0 || part < 0 || part >= parts) return;
  const LsMesh* m = c->mesh;
  const int32_t from = (int32_t)((int64_t)m->n_verts * part / parts);
  const int32_t to = (int32_t)((int64_t)m->n_verts * (part + 1) / parts);
  const float* r = c->rot;
  const float scale = c->scale, ox = c->ox, oy = c->oy;
  const float mx = c->lm[0], my = c->lm[1], mz = c->lm[2];
  const float* pos = m->pos;
  const float* nrm = m->nrm;
  for (int32_t v = from; v < to; v++) {
    const float x = pos[v * 3] - m->cx, y = pos[v * 3 + 1] - m->cy,
                z = pos[v * 3 + 2] - m->cz;
    c->sx[v] = ox + (r[0] * x + r[2] * z) * scale;
    c->sy[v] = oy - (r[3] * x + r[4] * y + r[5] * z) * scale;
    c->sz[v] = (r[6] * x + r[7] * y + r[8] * z) * scale;
    c->sd[v] = nrm[v * 3] * mx + nrm[v * 3 + 1] * my + nrm[v * 3 + 2] * mz;
  }
}

// The first output row of part `part` of `parts`: rows are shared out by
// the work in them, not evenly.
static int band_start(const LsContext* c, int32_t part, int32_t parts) {
  if (part <= 0) return 0;
  if (part >= parts) return c->h;
  const double target = c->row_work[c->h] * part / parts;
  int lo = 0, hi = c->h;
  while (lo < hi) {
    const int mid = (lo + hi) / 2;
    if (c->row_work[mid] < target) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

static inline int64_t floor_div(int64_t a, int64_t b) {  // b > 0
  int64_t q = a / b;
  return (a % b < 0) ? q - 1 : q;
}

static inline int64_t ceil_div(int64_t a, int64_t b) {  // b > 0
  int64_t q = a / b;
  return (a % b > 0) ? q + 1 : q;
}

static inline float shade_of(float d) {
  return AMBIENT + (1 - AMBIENT) * (d > 0 ? d : 0);
}

// The texel at (u, v), wrapping; smoothed between four texels unless
// `nearest`.
static inline uint32_t sample(const LsTexture* t, float u, float v,
                              int nearest) {
  u -= floorf(u);
  v -= floorf(v);
  if (nearest) {
    int x = (int)(u * t->w), y = (int)(v * t->h);
    if (x >= t->w) x = t->w - 1;
    if (y >= t->h) y = t->h - 1;
    uint32_t out;
    memcpy(&out, t->rgba + ((size_t)y * t->w + x) * 4, 4);
    return out;
  }
  const float fx = u * t->w - 0.5f, fy = v * t->h - 0.5f;
  const float flx = floorf(fx), fly = floorf(fy);
  const int wx = (int)((fx - flx) * 256), wy = (int)((fy - fly) * 256);
  int x0 = (int)flx, y0 = (int)fly;
  int x1 = x0 + 1, y1 = y0 + 1;
  if (x0 < 0) x0 += t->w;
  if (y0 < 0) y0 += t->h;
  if (x1 >= t->w) x1 -= t->w;
  if (y1 >= t->h) y1 -= t->h;
  const uint8_t* a = t->rgba + ((size_t)y0 * t->w + x0) * 4;
  const uint8_t* b = t->rgba + ((size_t)y0 * t->w + x1) * 4;
  const uint8_t* cc = t->rgba + ((size_t)y1 * t->w + x0) * 4;
  const uint8_t* d = t->rgba + ((size_t)y1 * t->w + x1) * 4;
  uint8_t out[4];
  for (int k = 0; k < 4; k++) {
    const int top = a[k] * (256 - wx) + b[k] * wx;
    const int bottom = cc[k] * (256 - wx) + d[k] * wx;
    out[k] = (uint8_t)((top * (256 - wy) + bottom * wy) >> 16);
  }
  uint32_t packed;
  memcpy(&packed, out, 4);
  return packed;
}

static inline uint32_t pack(int r, int g, int b, int a) {
  uint8_t out[4] = {(uint8_t)r, (uint8_t)g, (uint8_t)b, (uint8_t)a};
  uint32_t packed;
  memcpy(&packed, out, 4);
  return packed;
}

// Source over destination, both premultiplied.
static inline uint32_t over(uint32_t src, uint32_t dst) {
  uint8_t s[4], d[4];
  memcpy(s, &src, 4);
  memcpy(d, &dst, 4);
  const int inv = 255 - s[3];
  for (int k = 0; k < 4; k++) {
    d[k] = (uint8_t)(s[k] + (d[k] * inv + 127) / 255);
  }
  uint32_t out;
  memcpy(&out, d, 4);
  return out;
}

// Triangles over sample rows [Y0, Y1): the opaque ones (`blend` 0, every
// triangle of the mesh) or the translucent ones (`blend` 1), which are
// tested against the depth buffer but don't write it.
static void raster_tris(LsContext* c, int Y0, int Y1, int blend) {
  const LsMesh* m = c->mesh;
  const int W = c->W;
  const float* sx = c->sx;
  const float* sy = c->sy;
  const float* sz = c->sz;
  const float* sd = c->sd;
  const int textures = !(c->flags & LS_NO_TEXTURES) && m->uv;
  const int32_t count = blend ? m->n_translucent : m->n_tris;
  const float fY0 = (float)Y0, fY1 = (float)Y1, fW = (float)W;
  for (int32_t k = 0; k < count; k++) {
    const int32_t t = blend ? (int32_t)m->translucent[k] : k;
    uint32_t i0 = m->idx[t * 3], i1 = m->idx[t * 3 + 1], i2 = m->idx[t * 3 + 2];
    const float ay = sy[i0], by = sy[i1], cy = sy[i2];
    // Not in these rows (NaN fails every test and is skipped below).
    if ((ay < fY0 && by < fY0 && cy < fY0) ||
        (ay >= fY1 && by >= fY1 && cy >= fY1)) {
      continue;
    }
    const float ax = sx[i0], bx = sx[i1], cx = sx[i2];
    if ((ax < 0 && bx < 0 && cx < 0) || (ax >= fW && bx >= fW && cx >= fW)) {
      continue;
    }
    const int mat = m->tri_mat[t];
    const uint32_t argb = m->mat_color[mat];
    const int alpha = (int)(argb >> 24);
    if (!blend && alpha < 255) continue;
    if (!(fabsf(ax) < 1e8f && fabsf(bx) < 1e8f && fabsf(cx) < 1e8f &&
          fabsf(ay) < 1e8f && fabsf(by) < 1e8f && fabsf(cy) < 1e8f)) {
      continue;
    }
    // Sample coordinates in 1/16ths.
    int64_t X0 = llrintf(ax * 16), Y0f = llrintf(ay * 16);
    int64_t X1 = llrintf(bx * 16), Y1f = llrintf(by * 16);
    int64_t X2 = llrintf(cx * 16), Y2f = llrintf(cy * 16);
    int64_t area = (X1 - X0) * (Y2f - Y0f) - (X2 - X0) * (Y1f - Y0f);
    if (area == 0) continue;
    // The screen's y points down, so a front face has a negative area.
    const int front = area < 0;
    const int flags = m->mat_flags[mat];
    if (!front && !(flags & MAT_DOUBLE_SIDED)) continue;

    float s0, s1, s2;
    if (m->flat_shaded) {
      // The face's own normal, in view space.
      const float ux = bx - ax, uy = ay - by, uz = sz[i1] - sz[i0];
      const float wx = cx - ax, wy = ay - cy, wz = sz[i2] - sz[i0];
      float nx = uy * wz - uz * wy, ny = uz * wx - ux * wz,
            nz = ux * wy - uy * wx;
      const float len = sqrtf(nx * nx + ny * ny + nz * nz);
      float d = len > 0 ? (nx * c->light[0] + ny * c->light[1] +
                           nz * c->light[2]) /
                              len
                        : 0;
      if (!front) d = -d;
      s0 = s1 = s2 = shade_of(d);
    } else if (front) {
      s0 = shade_of(sd[i0]);
      s1 = shade_of(sd[i1]);
      s2 = shade_of(sd[i2]);
    } else {
      s0 = shade_of(-sd[i0]);
      s1 = shade_of(-sd[i1]);
      s2 = shade_of(-sd[i2]);
    }
    if (area < 0) {
      // Same triangle, turned so that its inside is where the edge
      // functions are positive.
      uint32_t ti = i1;
      i1 = i2;
      i2 = ti;
      int64_t tx = X1, ty = Y1f;
      X1 = X2;
      Y1f = Y2f;
      X2 = tx;
      Y2f = ty;
      float ts = s1;
      s1 = s2;
      s2 = ts;
      area = -area;
    }

    int64_t minY = Y0f < Y1f ? Y0f : Y1f, maxY = Y0f > Y1f ? Y0f : Y1f;
    if (Y2f < minY) minY = Y2f;
    if (Y2f > maxY) maxY = Y2f;
    // Rows whose sample centre (16·y + 8) is inside the triangle's rows.
    int64_t ya = ceil_div(minY - 8, 16), yb = floor_div(maxY - 8, 16);
    if (ya < Y0) ya = Y0;
    if (yb > Y1 - 1) yb = Y1 - 1;
    if (ya > yb) continue;

    // Edge functions E(x, y) = dx·y − dy·x + k, positive inside. An edge
    // that is neither a top nor a left one gives up the samples exactly on
    // it, so triangles sharing an edge never both draw a sample.
    const int64_t ex[3] = {X1 - X0, X2 - X1, X0 - X2};
    const int64_t ey[3] = {Y1f - Y0f, Y2f - Y1f, Y0f - Y2f};
    const int64_t px[3] = {X0, X1, X2};
    const int64_t py[3] = {Y0f, Y1f, Y2f};
    int64_t ek[3];
    for (int e = 0; e < 3; e++) {
      const int top_left = ey[e] < 0 || (ey[e] == 0 && ex[e] > 0);
      ek[e] = -ex[e] * py[e] + ey[e] * px[e] - (top_left ? 0 : 1);
    }

    // Planes of depth, shade and texture coordinates over the samples.
    const double x0 = X0 / 16.0, y0 = Y0f / 16.0;
    const double x1 = X1 / 16.0, y1 = Y1f / 16.0;
    const double x2 = X2 / 16.0, y2 = Y2f / 16.0;
    const double inv = 256.0 / (double)area;
    const double gx1 = (y2 - y0) * inv, gx2 = -(y1 - y0) * inv;
    const double gy1 = -(x2 - x0) * inv, gy2 = (x1 - x0) * inv;
    const double z0 = sz[i0], dz1 = sz[i1] - z0, dz2 = sz[i2] - z0;
    const double zdx = dz1 * gx1 + dz2 * gx2, zdy = dz1 * gy1 + dz2 * gy2;
    const double sdx = (s1 - s0) * gx1 + (s2 - s0) * gx2;
    const double sdy = (s1 - s0) * gy1 + (s2 - s0) * gy2;

    const LsTexture* tex = textures ? m->mat_tex[mat] : NULL;
    double u0 = 0, udx = 0, udy = 0, v0 = 0, vdx = 0, vdy = 0;
    if (tex) {
      const float* uv = m->uv;
      u0 = uv[i0 * 2];
      v0 = uv[i0 * 2 + 1];
      const double du1 = uv[i1 * 2] - u0, du2 = uv[i2 * 2] - u0;
      const double dv1 = uv[i1 * 2 + 1] - v0, dv2 = uv[i2 * 2 + 1] - v0;
      udx = du1 * gx1 + du2 * gx2;
      udy = du1 * gy1 + du2 * gy2;
      vdx = dv1 * gx1 + dv2 * gx2;
      vdy = dv1 * gy1 + dv2 * gy2;
    }
    const int cr = (argb >> 16) & 0xFF, cg = (argb >> 8) & 0xFF,
              cb = argb & 0xFF;
    const int constant = !tex && s0 == s1 && s1 == s2;
    uint32_t flat_color = 0;
    if (constant) {
      const int si = (int)(s0 * 256);
      int r = (cr * si) >> 8, g = (cg * si) >> 8, b = (cb * si) >> 8;
      if (blend) {
        r = r * alpha / 255;
        g = g * alpha / 255;
        b = b * alpha / 255;
      }
      flat_color = pack(r, g, b, alpha);
    }
    const int nearest = flags & MAT_NEAREST;

    for (int64_t y = ya; y <= yb; y++) {
      const int64_t Py = 16 * y + 8;
      int64_t xl = 0, xr = W - 1;
      for (int e = 0; e < 3; e++) {
        // E at sample x: a·x + b.
        const int64_t a = -ey[e] * 16;
        const int64_t b = ex[e] * Py + ek[e] - ey[e] * 8;
        if (a > 0) {
          const int64_t from = ceil_div(-b, a);
          if (from > xl) xl = from;
        } else if (a < 0) {
          const int64_t to = floor_div(b, -a);
          if (to < xr) xr = to;
        } else if (b < 0) {
          xr = -1;
        }
      }
      if (xl > xr) continue;
      const double fx = xl + 0.5 - x0, fy = y + 0.5 - y0;
      float z = (float)(z0 + zdx * fx + zdy * fy);
      const float zstep = (float)zdx;
      float* zrow = c->zbuf + (size_t)y * W;
      uint32_t* crow = c->cbuf + (size_t)y * W;
      if (constant && !blend) {
        for (int64_t x = xl; x <= xr; x++, z += zstep) {
          if (z > zrow[x]) {
            zrow[x] = z;
            crow[x] = flat_color;
          }
        }
        continue;
      }
      if (constant) {
        for (int64_t x = xl; x <= xr; x++, z += zstep) {
          if (z > zrow[x]) crow[x] = over(flat_color, crow[x]);
        }
        continue;
      }
      float s = (float)(s0 + sdx * fx + sdy * fy);
      const float sstep = (float)sdx;
      float u = (float)(u0 + udx * fx + udy * fy);
      float v = (float)(v0 + vdx * fx + vdy * fy);
      const float ustep = (float)udx, vstep = (float)vdx;
      for (int64_t x = xl; x <= xr;
           x++, z += zstep, s += sstep, u += ustep, v += vstep) {
        if (!(z > zrow[x])) continue;
        int si = (int)(s * 256);
        if (si < 0) si = 0;
        if (si > 256) si = 256;
        int r = (cr * si) >> 8, g = (cg * si) >> 8, b = (cb * si) >> 8;
        int a = alpha;
        if (tex) {
          uint8_t texel[4];
          const uint32_t packed = sample(tex, u, v, nearest);
          memcpy(texel, &packed, 4);
          // Cut-out textures: a see-through texel leaves a hole.
          if (texel[3] < 128) continue;
          r = r * texel[0] / 255;
          g = g * texel[1] / 255;
          b = b * texel[2] / 255;
        }
        if (blend) {
          crow[x] = over(pack(r * a / 255, g * a / 255, b * a / 255, a),
                         crow[x]);
        } else {
          zrow[x] = z;
          crow[x] = pack(r, g, b, 255);
        }
      }
    }
  }
}

// A line into the mask over sample rows [Y0, Y1), where it isn't behind
// the surface already drawn (`bias` lifts it toward the viewer).
static void draw_line(LsContext* c, int Y0, int Y1, float x0, float y0,
                      float z0, float x1, float y1, float z1, float bias,
                      uint8_t value) {
  const int thick = c->line_thick;
  const float pad = (float)thick;
  const float lo_x = -pad, hi_x = c->W + pad;
  const float lo_y = Y0 - pad, hi_y = Y1 + pad;
  const float dx = x1 - x0, dy = y1 - y0;
  if (!(fabsf(dx) < 1e8f && fabsf(dy) < 1e8f && fabsf(x0) < 1e8f &&
        fabsf(y0) < 1e8f)) {
    return;
  }
  // Keep the part inside the rows (Liang–Barsky).
  float t0 = 0, t1 = 1;
  const float p[4] = {-dx, dx, -dy, dy};
  const float q[4] = {x0 - lo_x, hi_x - x0, y0 - lo_y, hi_y - y0};
  for (int i = 0; i < 4; i++) {
    if (p[i] == 0) {
      if (q[i] < 0) return;
    } else {
      const float r = q[i] / p[i];
      if (p[i] < 0) {
        if (r > t1) return;
        if (r > t0) t0 = r;
      } else {
        if (r < t0) return;
        if (r < t1) t1 = r;
      }
    }
  }
  const float len = fabsf(dx) > fabsf(dy) ? fabsf(dx) : fabsf(dy);
  const int steps = (int)ceilf(len * (t1 - t0));
  const float dt = steps > 0 ? (t1 - t0) / steps : 0;
  const int off = thick / 2;
  for (int i = 0; i <= steps; i++) {
    const float t = t0 + dt * i;
    const int px = (int)floorf(x0 + dx * t) - off;
    const int py = (int)floorf(y0 + dy * t) - off;
    const float z = z0 + (z1 - z0) * t + bias;
    for (int yy = py; yy < py + thick; yy++) {
      if (yy < Y0 || yy >= Y1) continue;
      for (int xx = px; xx < px + thick; xx++) {
        if (xx < 0 || xx >= c->W) continue;
        const size_t at = (size_t)yy * c->W + xx;
        if (z >= c->zbuf[at] && c->mask[at] < value) c->mask[at] = value;
      }
    }
  }
}

static void raster_wireframe(LsContext* c, int Y0, int Y1) {
  const LsMesh* m = c->mesh;
  const float fY0 = (float)(Y0 - c->line_thick),
              fY1 = (float)(Y1 + c->line_thick);
  // Lifted off its own surface by about two output pixels of depth.
  const float bias = 2.0f * c->ss;
  for (int32_t t = 0; t < m->n_tris; t++) {
    const uint32_t i[3] = {m->idx[t * 3], m->idx[t * 3 + 1], m->idx[t * 3 + 2]};
    const float ay = c->sy[i[0]], by = c->sy[i[1]], cy = c->sy[i[2]];
    if ((ay < fY0 && by < fY0 && cy < fY0) ||
        (ay >= fY1 && by >= fY1 && cy >= fY1)) {
      continue;
    }
    const float ax = c->sx[i[0]], bx = c->sx[i[1]], cx = c->sx[i[2]];
    const float area = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay);
    if (!(area < 0) && !(m->mat_flags[m->tri_mat[t]] & MAT_DOUBLE_SIDED)) {
      continue;
    }
    for (int e = 0; e < 3; e++) {
      const uint32_t a = i[e], b = i[(e + 1) % 3];
      draw_line(c, Y0, Y1, c->sx[a], c->sy[a], c->sz[a], c->sx[b], c->sy[b],
                c->sz[b], bias, MASK_WIRE);
    }
  }
}

// Draws part `part` of `parts` of the frame's rows into `out`, the whole
// picture's premultiplied RGBA (w × h × 4 bytes).
LS_EXPORT void ls_frame_band(LsContext* c, int32_t part, int32_t parts,
                             uint8_t* out) {
  if (!c || !c->mesh || parts <= 0 || part < 0 || part >= parts) return;
  const int y0 = band_start(c, part, parts);
  const int y1 = band_start(c, part + 1, parts);
  if (y0 >= y1) return;
  const int ss = c->ss, W = c->W;
  const int Y0 = y0 * ss, Y1 = y1 * ss;
  const size_t first = (size_t)Y0 * W, count = (size_t)(Y1 - Y0) * W;
  for (size_t i = 0; i < count; i++) c->zbuf[first + i] = -FLT_MAX;
  memset(c->cbuf + first, 0, count * sizeof(uint32_t));
  memset(c->mask + first, 0, count);

  raster_tris(c, Y0, Y1, 0);
  if (c->mesh->n_translucent) raster_tris(c, Y0, Y1, 1);
  if (c->flags & LS_GRID) {
    for (int i = 0; i < GRID_LINES; i++) {
      const float* g = c->grid[i];
      draw_line(c, Y0, Y1, g[0], g[1], g[2], g[3], g[4], g[5], 0, MASK_GRID);
    }
  }
  if (c->flags & LS_WIREFRAME) raster_wireframe(c, Y0, Y1);

  // Lines over the picture, then the samples of each pixel averaged.
  if (c->flags & (LS_GRID | LS_WIREFRAME)) {
    const uint32_t lc = c->line_color;
    const int la = (int)(lc >> 24);
    uint32_t line_px[3] = {0, 0, 0};
    for (int v = MASK_GRID; v <= MASK_WIRE; v++) {
      // Grid lines are fainter than the wireframe.
      const int a = la * (v == MASK_WIRE ? 179 : 64) / 255;
      line_px[v] = pack((int)((lc >> 16) & 0xFF) * a / 255,
                        (int)((lc >> 8) & 0xFF) * a / 255,
                        (int)(lc & 0xFF) * a / 255, a);
    }
    for (size_t i = first; i < first + count; i++) {
      if (c->mask[i]) c->cbuf[i] = over(line_px[c->mask[i]], c->cbuf[i]);
    }
  }
  const int w = c->w;
  for (int y = y0; y < y1; y++) {
    uint8_t* dst = out + (size_t)y * w * 4;
    const uint8_t* src = (const uint8_t*)(c->cbuf + (size_t)y * ss * W);
    if (ss == 1) {
      memcpy(dst, src, (size_t)w * 4);
    } else if (ss == 2) {
      const uint8_t* below = src + (size_t)W * 4;
      for (int i = 0; i < w * 4; i += 4) {
        const uint8_t* p = src + i * 2;
        const uint8_t* q = below + i * 2;
        dst[i] = (uint8_t)((p[0] + p[4] + q[0] + q[4] + 2) >> 2);
        dst[i + 1] = (uint8_t)((p[1] + p[5] + q[1] + q[5] + 2) >> 2);
        dst[i + 2] = (uint8_t)((p[2] + p[6] + q[2] + q[6] + 2) >> 2);
        dst[i + 3] = (uint8_t)((p[3] + p[7] + q[3] + q[7] + 2) >> 2);
      }
    } else {
      const int n = ss * ss;
      for (int x = 0; x < w; x++) {
        int sum[4] = {0, 0, 0, 0};
        for (int j = 0; j < ss; j++) {
          const uint8_t* p = src + ((size_t)j * W + (size_t)x * ss) * 4;
          for (int i = 0; i < ss * 4; i += 4) {
            sum[0] += p[i];
            sum[1] += p[i + 1];
            sum[2] += p[i + 2];
            sum[3] += p[i + 3];
          }
        }
        dst[x * 4] = (uint8_t)(sum[0] / n);
        dst[x * 4 + 1] = (uint8_t)(sum[1] / n);
        dst[x * 4 + 2] = (uint8_t)(sum[2] / n);
        dst[x * 4 + 3] = (uint8_t)(sum[3] / n);
      }
    }
  }
}
