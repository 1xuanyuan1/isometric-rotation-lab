shader_type canvas_item;
render_mode unshaded;
uniform float wetness = 1.0;
uniform float rain_amount = 0.65;
uniform float clock_time = 0.0;
uniform vec2 origin;
uniform vec2 focus;
uniform float yaw = 0.785;
uniform float camera_zoom = 1.0;
uniform float map_size = 32.0;
uniform sampler2D height_map : filter_nearest, repeat_disable;
uniform bool puddles_on = true;
uniform bool reflections_on = true;
varying vec2 screen_pos;
varying vec4 vertex_tint;
float hash(vec2 p) { return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453); }
float noise(vec2 p) {
 vec2 i=floor(p); vec2 f=fract(p); f=f*f*(3.0-2.0*f);
 return mix(mix(hash(i),hash(i+vec2(1,0)),f.x),mix(hash(i+vec2(0,1)),hash(i+vec2(1,1)),f.x),f.y);
}
vec2 world(vec2 screen, float h) {
 vec2 q=(screen-origin)/camera_zoom; q.y=(q.y+h)/0.52;
 return vec2(cos(yaw)*q.x+sin(yaw)*q.y,-sin(yaw)*q.x+cos(yaw)*q.y)+focus;
}
float pool(vec2 p,float h) {
 float n=noise(p/39.0)*0.74+noise(p/13.0)*0.26;
 return h<1.0 ? 1.0 : smoothstep(0.46,0.53,n) * (puddles_on ? 1.0 : 0.0);
}
// Fixed world-space impact centers. Neighbor cells prevent rings being cut at borders.
vec3 impact(vec2 p) {
 vec2 cell=floor(p/24.0); vec3 result=vec3(0.0);
 for(int y=-1;y<=1;y++) { for(int x=-1;x<=1;x++) {
  vec2 id=cell+vec2(float(x),float(y)); float seed=hash(id);
  vec2 center=(id+vec2(0.2+0.6*seed,0.2+0.6*hash(id+47.0)))*24.0;
  float t=fract(clock_time*(0.65+rain_amount*0.75)+seed*17.0);
  float d=length(p-center); float radius=1.0+t*9.0;
  float ring=(1.0-smoothstep(0.3,1.1,abs(d-radius)))*(1.0-t);
  float active=step(seed,0.2+rain_amount*0.7);
  result.x+=ring*active;
  result.y+=exp(-d*d*0.18)*max(0.0,1.0-t*9.0)*active;
  result.z+=sin((d-radius)*1.8)*exp(-abs(d-radius)*0.6)*(1.0-t)*active;
 }}
 return result;
}
void vertex() { screen_pos=VERTEX; vertex_tint=COLOR; }
void fragment() {
 vec4 tint=vertex_tint;
 bool top=UV.y < -0.5;
 bool reflection=UV.y > 1.5;
 vec4 col;
 if(top) {
  float h=UV.x; vec2 p=world(screen_pos,h);
  float mask=pool(p,h)*wetness;
  vec3 rip=impact(p)*rain_amount*wetness;
  // Distort the procedural ground detail beneath the shallow water.
  vec2 refracted=p+vec2(rip.z,-rip.z*0.6)*mask*1.9;
  float grain=noise(refracted*0.65)-0.5;
  col=vec4(tint.rgb*(1.0+grain*0.07),tint.a);
  col.rgb=mix(col.rgb,col.rgb*vec3(0.55,0.68,0.77),wetness);
  vec3 sky=vec3(0.22,0.34,0.40)+noise(p/68.0+clock_time*0.014)*0.08;
  col.rgb=mix(col.rgb,sky,mask*0.64);
  float edge=(1.0-abs(pool(p,h)*2.0-1.0))*wetness;
  col.rgb+=vec3(0.16,0.23,0.24)*edge*0.35;
  col.rgb+=vec3(0.42,0.59,0.65)*(rip.x*mask*0.40+rip.y*0.9);
 } else if(reflection) {
  float h=tint.a*64.0;
  vec2 p=world(screen_pos,h);
  vec2 tile=floor(p/22.0+map_size/2.0+0.5);
  vec2 map_uv=(tile+0.5)/map_size;
  bool inside=all(greaterThanEqual(tile,vec2(0))) && all(lessThan(tile,vec2(map_size)));
  float actual_h=texture(height_map,map_uv).r*255.0;
  float valid=(inside && abs(actual_h-h)<0.5) ? 1.0 : 0.0;
  vec3 rip=impact(p);
  vec2 coord=UV-vec2(0,2);
  float frame_width=(coord.y>64.5/2048.0 ? 21.0 : 32.0)/1024.0;
  float frame=floor(coord.x/frame_width);
  coord.x=clamp(coord.x+(sin(p.y*0.4+clock_time*2.2)+rip.z*2.0)*0.0005*wetness,frame*frame_width+0.0005,(frame+1.0)*frame_width-0.0005);
  col=texture(TEXTURE,coord);
  col.rgb=mix(col.rgb*vec3(0.39,0.53,0.60),vec3(0.18,0.29,0.34),0.24);
  col.a*=pool(p,h)*wetness*valid*0.58*(reflections_on ? 1.0 : 0.0);
 } else {
  col=texture(TEXTURE,UV)*tint;
  col.rgb=mix(col.rgb,col.rgb*vec3(0.57,0.69,0.77),wetness);
 }
 COLOR=col;
}
