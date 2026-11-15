// Loot Silo's FBX reader: loads a file with ufbx (native/ufbx/, MIT /
// public domain) and flattens it to one triangle list the app can draw:
// every mesh instance in its node's transform, y-up, three vertices per
// triangle, with a material per triangle. Skins and animations are
// ignored. Bound by lib/core/model_fbx.dart.

#include <stdint.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>

#include "ufbx/ufbx.h"

#if defined(_WIN32)
#define LS_EXPORT __declspec(dllexport)
#else
#define LS_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

typedef struct LsFbxMaterial {
  uint32_t argb;
  int32_t double_sided;
  const char* name;           // owned by the scene
  const char* texture;        // relative file name, or ""
  const char* texture_abs;    // absolute file name as stored, or ""
  const uint8_t* texture_data;  // an image stored inside the file, or NULL
  int64_t texture_size;
} LsFbxMaterial;

typedef struct LsFbx {
  ufbx_scene* scene;
  int64_t n_tris;
  float* pos;   // 9 per triangle
  float* nrm;   // 9 per triangle
  float* uv;    // 6 per triangle
  int32_t has_uv;
  uint32_t* tri_mat;
  int32_t n_mats;
  LsFbxMaterial* mats;
  char error[1024];
} LsFbx;

LS_EXPORT void ls_fbx_free(LsFbx* f) {
  if (!f) return;
  ufbx_free_scene(f->scene);
  free(f->pos);
  free(f->nrm);
  free(f->uv);
  free(f->tri_mat);
  free(f->mats);
  free(f);
}

static uint32_t channel(double v) {
  if (!(v > 0)) return 0;
  if (v > 1) return 255;
  return (uint32_t)(v * 255 + 0.5);
}

static void fill_material(LsFbxMaterial* out, const ufbx_material* m) {
  const ufbx_material_map* color = m->pbr.base_color.has_value ||
                                           m->pbr.base_color.texture
                                       ? &m->pbr.base_color
                                       : &m->fbx.diffuse_color;
  double r = 0.8, g = 0.8, b = 0.8, a = 1;
  if (color->has_value) {
    r = color->value_vec4.x;
    g = color->value_vec4.y;
    b = color->value_vec4.z;
  }
  // Exporters disagree on what a zero opacity means; only a partly
  // see-through value is taken at its word.
  if (m->pbr.opacity.has_value && m->pbr.opacity.value_real > 0.02 &&
      m->pbr.opacity.value_real < 1) {
    a = m->pbr.opacity.value_real;
  }
  out->name = m->name.data ? m->name.data : "";
  out->texture = "";
  out->texture_abs = "";
  const ufbx_texture* t = color->texture_enabled ? color->texture : NULL;
  if (t && t->file_textures.count > 0) t = t->file_textures.data[0];
  if (t) {
    // A textured material is drawn in the texture's own colours.
    if (!color->has_value || (r == 0 && g == 0 && b == 0)) r = g = b = 1;
    if (t->content.size > 0) {
      out->texture_data = (const uint8_t*)t->content.data;
      out->texture_size = (int64_t)t->content.size;
    }
    if (t->relative_filename.data) out->texture = t->relative_filename.data;
    if (t->absolute_filename.data) out->texture_abs = t->absolute_filename.data;
    if (!out->texture[0] && t->filename.data) out->texture = t->filename.data;
  }
  out->argb = channel(a) << 24 | channel(r) << 16 | channel(g) << 8 | channel(b);
  out->double_sided = m->features.double_sided.enabled ? 1 : 0;
}

// Loads the FBX in `data`. `filename` (UTF-8, may be NULL) lets ufbx work
// out relative texture paths. Never NULL unless memory ran out: check
// ls_fbx_error.
LS_EXPORT LsFbx* ls_fbx_load(const uint8_t* data, int64_t size,
                             const char* filename, int64_t max_triangles) {
  LsFbx* f = (LsFbx*)calloc(1, sizeof(LsFbx));
  if (!f) return NULL;
  ufbx_load_opts opts = {0};
  opts.target_axes = ufbx_axes_right_handed_y_up;
  opts.generate_missing_normals = true;
  opts.ignore_animation = true;
  opts.skip_skin_vertices = true;
  opts.clean_skin_weights = false;
  if (filename) {
    opts.filename.data = filename;
    opts.filename.length = strlen(filename);
  }
  ufbx_error error;
  f->scene = ufbx_load_memory(data, (size_t)size, &opts, &error);
  if (!f->scene) {
    ufbx_format_error(f->error, sizeof(f->error), &error);
    return f;
  }
  const ufbx_scene* scene = f->scene;

  // Materials in the scene's order, then a plain one for faces without.
  f->n_mats = (int32_t)scene->materials.count + 1;
  f->mats = (LsFbxMaterial*)calloc((size_t)f->n_mats, sizeof(LsFbxMaterial));
  if (!f->mats) {
    strcpy(f->error, "Out of memory");
    return f;
  }
  for (size_t i = 0; i < scene->materials.count; i++) {
    fill_material(&f->mats[i], scene->materials.data[i]);
  }
  LsFbxMaterial* plain = &f->mats[f->n_mats - 1];
  plain->argb = 0xFFC8C8C8;
  plain->name = "";
  plain->texture = "";
  plain->texture_abs = "";

  // Hidden nodes are left out, unless that leaves nothing.
  for (int pass = 0; pass < 2 && f->n_tris == 0; pass++) {
    int64_t total = 0;
    size_t max_face = 0;
    for (size_t n = 0; n < scene->nodes.count; n++) {
      const ufbx_node* node = scene->nodes.data[n];
      if (!node->mesh || (pass == 0 && !node->visible)) continue;
      total += (int64_t)node->mesh->num_triangles;
      if (node->mesh->max_face_triangles > max_face) {
        max_face = node->mesh->max_face_triangles;
      }
    }
    if (total == 0) continue;
    if (total > max_triangles) {
      // Too big to draw: say how big and stop before allocating.
      f->n_tris = total;
      strcpy(f->error, "Too large to preview");
      return f;
    }
    f->pos = (float*)malloc(sizeof(float) * 9 * (size_t)total);
    f->nrm = (float*)malloc(sizeof(float) * 9 * (size_t)total);
    f->uv = (float*)calloc(6 * (size_t)total, sizeof(float));
    f->tri_mat = (uint32_t*)malloc(sizeof(uint32_t) * (size_t)total);
    uint32_t* tri = (uint32_t*)malloc(sizeof(uint32_t) * 3 * (max_face + 1));
    if (!f->pos || !f->nrm || !f->uv || !f->tri_mat || !tri) {
      free(tri);
      strcpy(f->error, "Out of memory");
      return f;
    }
    int64_t at = 0;
    for (size_t n = 0; n < scene->nodes.count; n++) {
      const ufbx_node* node = scene->nodes.data[n];
      const ufbx_mesh* mesh = node->mesh;
      if (!mesh || (pass == 0 && !node->visible)) continue;
      const ufbx_matrix to_world = node->geometry_to_world;
      const ufbx_matrix for_normals = ufbx_matrix_for_normals(&to_world);
      // A mirroring transform turns the triangles inside out.
      const ufbx_vec3 c0 = to_world.cols[0], c1 = to_world.cols[1],
                      c2 = to_world.cols[2];
      const double det = c0.x * (c1.y * c2.z - c1.z * c2.y) -
                         c0.y * (c1.x * c2.z - c1.z * c2.x) +
                         c0.z * (c1.x * c2.y - c1.y * c2.x);
      const int flip = det < 0;
      const int has_uv = mesh->vertex_uv.exists;
      const int has_normal = mesh->vertex_normal.exists;
      for (size_t fi = 0; fi < mesh->faces.count; fi++) {
        const ufbx_face face = mesh->faces.data[fi];
        if (face.num_indices < 3) continue;
        uint32_t material = (uint32_t)f->n_mats - 1;
        if (fi < mesh->face_material.count) {
          const uint32_t slot = mesh->face_material.data[fi];
          const ufbx_material* m =
              slot < node->materials.count   ? node->materials.data[slot]
              : slot < mesh->materials.count ? mesh->materials.data[slot]
                                             : NULL;
          if (m && m->typed_id < scene->materials.count) material = m->typed_id;
        }
        const uint32_t count =
            ufbx_triangulate_face(tri, 3 * (max_face + 1), mesh, face);
        for (uint32_t t = 0; t < count && at < total; t++, at++) {
          for (int k = 0; k < 3; k++) {
            const int corner = flip && k > 0 ? 3 - k : k;
            const uint32_t ix = tri[t * 3 + corner];
            const ufbx_vec3 p = ufbx_transform_position(
                &to_world, ufbx_get_vertex_vec3(&mesh->vertex_position, ix));
            float* op = f->pos + at * 9 + k * 3;
            op[0] = (float)p.x;
            op[1] = (float)p.y;
            op[2] = (float)p.z;
            float* on = f->nrm + at * 9 + k * 3;
            on[0] = 0;
            on[1] = 1;
            on[2] = 0;
            if (has_normal) {
              ufbx_vec3 nv = ufbx_transform_direction(
                  &for_normals, ufbx_get_vertex_vec3(&mesh->vertex_normal, ix));
              const double len = nv.x * nv.x + nv.y * nv.y + nv.z * nv.z;
              if (len > 0) {
                const double inv = (flip ? -1.0 : 1.0) / sqrt(len);
                on[0] = (float)(nv.x * inv);
                on[1] = (float)(nv.y * inv);
                on[2] = (float)(nv.z * inv);
              }
            }
            if (has_uv) {
              const ufbx_vec2 uv = ufbx_get_vertex_vec2(&mesh->vertex_uv, ix);
              // FBX's v points up; the app keeps image orientation.
              f->uv[at * 6 + k * 2] = (float)uv.x;
              f->uv[at * 6 + k * 2 + 1] = (float)(1 - uv.y);
              f->has_uv = 1;
            }
          }
          f->tri_mat[at] = material;
        }
      }
    }
    free(tri);
    f->n_tris = at;
  }
  if (f->n_tris == 0) strcpy(f->error, "No triangles");
  return f;
}

// "" when the file loaded.
LS_EXPORT const char* ls_fbx_error(const LsFbx* f) { return f->error; }
LS_EXPORT int64_t ls_fbx_triangles(const LsFbx* f) { return f->n_tris; }
LS_EXPORT int32_t ls_fbx_has_uv(const LsFbx* f) { return f->has_uv; }
LS_EXPORT const float* ls_fbx_positions(const LsFbx* f) { return f->pos; }
LS_EXPORT const float* ls_fbx_normals(const LsFbx* f) { return f->nrm; }
LS_EXPORT const float* ls_fbx_uvs(const LsFbx* f) { return f->uv; }
LS_EXPORT const uint32_t* ls_fbx_triangle_materials(const LsFbx* f) {
  return f->tri_mat;
}
LS_EXPORT int32_t ls_fbx_material_count(const LsFbx* f) { return f->n_mats; }
LS_EXPORT const LsFbxMaterial* ls_fbx_material(const LsFbx* f, int32_t i) {
  return i >= 0 && i < f->n_mats ? &f->mats[i] : NULL;
}
