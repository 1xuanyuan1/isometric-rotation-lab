// Height field comes from the painted Ground TileMapLayer's bed_height values.
uniform bool river_enabled = true;
uniform float water_level = 0.52;
uniform float flow_speed = 0.65;
uniform sampler2D river_bed : filter_linear, repeat_disable;
float bed_at(vec2 p) {
 return texture(river_bed,(p/22.0+vec2(map_size/2.0+0.5))/map_size).r;
}
float river_mask(vec2 p) {
 return smoothstep(-0.012,0.012,water_level-bed_at(p));
}
vec3 sediment(vec2 p) {
 vec2 cell=floor(p*0.22); vec2 f=fract(p*0.22);
 float seed=hash(cell);
 vec2 center=vec2(0.25+0.5*seed,0.25+0.5*hash(cell+17.0));
 float d=length((f-center)*vec2(1.0,1.4));
 float stone=1.0-smoothstep(0.21,0.35,d);
 float edge=1.0-smoothstep(0.31,0.39,d);
 vec3 sand=mix(vec3(0.38,0.36,0.27),vec3(0.58,0.55,0.40),noise(p*0.12));
 sand=mix(sand,vec3(0.23,0.28,0.25),edge*0.5);
 return mix(sand,mix(vec3(0.40,0.45,0.39),vec3(0.67,0.67,0.52),seed),stone);
}
vec3 river_color(vec2 p,vec3 grass,vec3 rip) {
 float bed=bed_at(p);
 float channel=1.0-smoothstep(0.92,0.995,bed);
 float depth=water_level-bed;
 float water=river_mask(p);
 vec2 grad=vec2(bed_at(p+vec2(2,0))-bed_at(p-vec2(2,0)),bed_at(p+vec2(0,2))-bed_at(p-vec2(0,2)));
 vec2 flow=normalize(vec2(-grad.y,grad.x)+vec2(0.0001,0.0002));
 if(flow.y<0.0) flow=-flow;
 float t=clock_time*flow_speed;
 vec2 current=p-flow*t*17.0;
 float wave=sin(dot(p,vec2(0.06,0.15))-t*2.7)+noise(current*0.14)*2.0-1.0;
 vec2 refracted=p+vec2(wave,rip.z)*1.5*water;
 vec3 bed_color=sediment(refracted);
 // Recessed banks: warm rim, dark interior, and a light upper lip.
 float slope=clamp(length(grad)*7.0,0.0,1.0);
 bed_color*=1.0-slope*0.38;
 float lip=smoothstep(0.87,0.94,bed)*(1.0-smoothstep(0.94,0.99,bed));
 bed_color+=vec3(0.20,0.18,0.10)*lip;
 vec3 water_color=mix(bed_color,vec3(0.055,0.31,0.37),clamp(depth*1.3+0.22,0.0,0.9));
 float glint=smoothstep(0.69,0.84,noise(current*vec2(0.17,0.075)))*0.19;
 water_color+=vec3(0.43,0.72,0.71)*(glint+rip.x*0.18);
 float shore=(1.0-smoothstep(0.008,0.045,abs(depth)))*(0.55+0.45*noise(current*0.25));
 water_color=mix(water_color,vec3(0.72,0.85,0.73),shore*0.70);
 vec3 ground=mix(grass,bed_color,channel);
 return mix(ground,water_color,water)*(1.0-wetness*0.20);
}
