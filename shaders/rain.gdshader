shader_type canvas_item;
render_mode unshaded;
uniform float strength=0.65;
uniform float clock_time=0.0;
uniform vec2 resolution=vec2(1440,900);
float hash(vec2 p) {return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
void fragment() {
 vec2 p=UV*resolution;
 float rain=0.0;
 for(int i=0;i<3;i++) {
  float layer=float(i); float scale=0.75+layer*0.42;
  vec2 q=vec2(p.x+p.y*0.20,p.y-clock_time*(410.0+layer*150.0))*scale;
  q.y+=hash(vec2(floor(q.x/31.0),layer))*115.0;
  vec2 cell=floor(q/vec2(31.0,115.0)); vec2 local=fract(q/vec2(31.0,115.0));
  float seed=hash(cell+layer*87.0);
  float x=0.12+0.76*hash(cell+19.0);
  float line=(1.0-smoothstep(0.007,0.031,abs(local.x-x)));
  float streak=smoothstep(0.0,0.07,local.y)*(1.0-smoothstep(0.10,0.29,local.y));
  rain+=line*streak*step(seed,strength*0.62)*(0.28+0.18*layer);
 }
 float border=smoothstep(325.0,365.0,p.x)*smoothstep(100.0,140.0,p.y)*(1.0-smoothstep(770.0,805.0,p.y));
 COLOR=vec4(vec3(0.64,0.80,0.88),rain*border*min(strength*3.0,1.0));
}
