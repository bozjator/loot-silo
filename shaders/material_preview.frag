#version 460 core

#include <flutter/runtime_effect.glsl>

// A lit PBR preview of one material: a sphere (uMode 0) or a flat tile
// (uMode 1). Maps missing from the material are flagged off and use
// neutral values: white colour, flat normal, roughness 0.5, metal 0, AO 1.

uniform vec2 uSize;
// 0 sphere, 1 plane.
uniform float uMode;
// Fraction of the stage's short side the sphere / tile fills.
uniform float uZoom;
uniform float uTiling;
// Turn of the sphere around its vertical axis, radians.
uniform float uYaw;
// Width / height of the maps, so texels stay square.
uniform float uAspect;
// Direction towards the light, view space (x right, y up, z to the viewer).
uniform vec3 uLight;
// 1 when the map is there: color, normal, roughness, metalness, ao.
uniform float uHasColor;
uniform float uHasNormal;
uniform float uHasRough;
uniform float uHasMetal;
uniform float uHasAO;
// 1 for DirectX normal maps (green points down).
uniform float uNormalDX;

uniform sampler2D uColor;
uniform sampler2D uNormal;
uniform sampler2D uRough;
uniform sampler2D uMetal;
uniform sampler2D uAO;

out vec4 fragColor;

const float PI = 3.14159265;

void main() {
  vec2 frag = FlutterFragCoord().xy;
  float side = min(uSize.x, uSize.y) * uZoom;
  // -1..1 over the sphere / tile, y up.
  vec2 q = (frag - uSize * 0.5) / (side * 0.5);
  q.y = -q.y;
  float px = 2.0 / side;

  vec3 n;
  vec3 t;
  vec2 uv;
  float alpha = 1.0;
  if (uMode < 0.5) {
    float r2 = dot(q, q);
    if (r2 > 1.0 + 2.0 * px) {
      fragColor = vec4(0.0);
      return;
    }
    alpha = 1.0 - smoothstep(1.0 - px, 1.0 + px, sqrt(r2));
    n = vec3(q, sqrt(max(0.0, 1.0 - r2)));
    // Turned sphere: texture coordinates from the turned normal.
    float c = cos(uYaw);
    float s = sin(uYaw);
    vec3 o = vec3(c * n.x + s * n.z, n.y, -s * n.x + c * n.z);
    uv = vec2(atan(o.x, o.z) / (2.0 * PI) + 0.5, acos(clamp(o.y, -1.0, 1.0)) / PI);
    // Once around is twice as long as top to bottom.
    uv.x *= 2.0 / uAspect;
    t = normalize(vec3(n.z, 0.0, -n.x) + vec3(1e-4, 0.0, 0.0));
  } else {
    if (abs(q.x) > 1.0 || abs(q.y) > 1.0) {
      fragColor = vec4(0.0);
      return;
    }
    n = vec3(0.0, 0.0, 1.0);
    t = vec3(1.0, 0.0, 0.0);
    uv = vec2(q.x * 0.5 + 0.5, (0.5 - q.y * 0.5) * uAspect);
  }
  uv = fract(uv * uTiling);
  vec3 b = cross(n, t);

  vec3 albedo = uHasColor > 0.5 ? pow(texture(uColor, uv).rgb, vec3(2.2)) : vec3(0.8);
  float rough = uHasRough > 0.5 ? texture(uRough, uv).r : 0.5;
  rough = clamp(rough, 0.04, 1.0);
  float metal = uHasMetal > 0.5 ? texture(uMetal, uv).r : 0.0;
  float ao = uHasAO > 0.5 ? texture(uAO, uv).r : 1.0;
  if (uHasNormal > 0.5) {
    vec3 m = texture(uNormal, uv).rgb * 2.0 - 1.0;
    if (uNormalDX > 0.5) m.y = -m.y;
    n = normalize(t * m.x + b * m.y + n * m.z);
  }

  vec3 v = vec3(0.0, 0.0, 1.0);
  vec3 l = normalize(uLight);
  vec3 h = normalize(l + v);
  float ndl = max(dot(n, l), 0.0);
  float ndv = max(dot(n, v), 1e-3);
  float ndh = max(dot(n, h), 0.0);
  float vdh = max(dot(v, h), 0.0);

  float a = rough * rough;
  float a2 = a * a;
  float d = ndh * ndh * (a2 - 1.0) + 1.0;
  float dist = a2 / (PI * d * d);
  float k = (rough + 1.0) * (rough + 1.0) / 8.0;
  float geo = (ndl / (ndl * (1.0 - k) + k)) * (ndv / (ndv * (1.0 - k) + k));
  vec3 f0 = mix(vec3(0.04), albedo, metal);
  vec3 fres = f0 + (1.0 - f0) * pow(1.0 - vdh, 5.0);
  vec3 spec = dist * geo * fres / max(4.0 * ndl * ndv, 1e-3);
  vec3 diffuse = (1.0 - fres) * (1.0 - metal) * albedo / PI;
  vec3 lit = (diffuse + spec) * 3.0 * ndl;
  vec3 ambient = (albedo * (1.0 - metal) + f0 * metal) * 0.1 * ao;
  vec3 col = lit * mix(1.0, ao, 0.5) + ambient;
  col = col / (col + 1.0);
  col = pow(col, vec3(1.0 / 2.2));
  fragColor = vec4(col * alpha, alpha);
}
