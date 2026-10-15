shader_type canvas_item;
render_mode unshaded;
uniform float seed_val = 29.0;
uniform int num_continents = 2;
uniform float continent_size = 0.5;
uniform float sea_level = 0.5;
uniform float continent_spacing = 0.92;
uniform float island_amount = 0.38;

float hash(vec2 p) { return fract(sin(dot(p,vec2(127.1,311.7)) + seed_val * .013) * 43758.5453); }
float noise(vec2 p) {
    vec2 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
    return mix(mix(hash(i),hash(i+vec2(1,0)),f.x),mix(hash(i+vec2(0,1)),hash(i+vec2(1,1)),f.x),f.y);
}
void fragment() {
    vec2 p = (UV-.5)*vec2(1.5,1.0);
    vec2 warp=vec2(noise(p*4.0+3.7),noise(p*4.0+12.2))-.5;
    vec2 q=p+warp*.12;
    float elevation=0.0;
    for(int i=0;i<8;i++) {
        if(i>=num_continents) break;
        float fi=float(i), angle=fi*2.39996 + seed_val*.00027;
        vec2 center=num_continents==1?vec2(0):vec2(cos(angle),sin(angle)) * (.16+continent_spacing*.13);
        vec2 d=(q-center)*vec2(1.0,.82);
        float radius=mix(.15,.31,continent_size)*mix(1.35,.72,float(num_continents-1)/7.0);
        float core=1.0-smoothstep(radius*.2,radius*1.45,length(d));
        elevation=max(elevation,core);
    }
    float detail=noise(q*7.0)*.12+noise(q*17.0)*.045;
    float islands=pow(noise(q*9.0+22.0),5.0)*island_amount*.4;
    float coastline=clamp(elevation+detail+islands-sea_level*.46-.12,0.0,1.0);
    float ridge=pow(1.0-abs(noise(q*8.0+31.0)*2.0-1.0),7.0);
    float h=coastline*.68+ridge*smoothstep(.22,.4,coastline)*.28;
    COLOR=vec4(vec3(h),1);
}
