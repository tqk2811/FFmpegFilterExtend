@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let aspect = vec2f(globals.size.x / globals.size.y, 1.0);
    let a = radians(params.angle);
    let rot = mat2x2f(cos(a), sin(a), -sin(a), cos(a));
    let p = (gpufx_uv(id) - 0.5) * aspect;
    let uv = (rot * p) / max(params.zoom, 0.0001) / aspect + params.center;
    if (any(uv < vec2f(0.0)) || any(uv > vec2f(1.0))) {
        gpufx_write(id, params.background);
        return;
    }
    gpufx_write(id, textureSampleLevel(src, smp, uv, 0.0));
}
