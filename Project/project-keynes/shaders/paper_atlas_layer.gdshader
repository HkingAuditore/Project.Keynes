shader_type canvas_item;
render_mode unshaded;
uniform sampler2D height_map : filter_linear;
uniform sampler2D paper_grain : filter_linear, repeat_enable;
uniform float threshold = .15;
uniform vec4 paper_color : source_color = vec4(.9,.83,.65,1);
uniform vec2 pixel = vec2(0.0013020833,0.001953125);
float cut(vec2 uv) { return smoothstep(threshold-.004,threshold+.004,texture(height_map,uv).r); }
void fragment() {
    float mask=cut(UV);
    float contact=cut(UV-pixel*vec2(2,3));
    float cast=(cut(UV-pixel*vec2(5,8)) + cut(UV-pixel*vec2(9,12)) + cut(UV-pixel*vec2(13,17)))/3.0;
    float edge=clamp(mask-cut(UV+pixel*vec2(1,1)),0.0,1.0);
    float shade=clamp(mask-contact,0.0,1.0);
    vec3 grain=texture(paper_grain,fract(UV*2.3)*.35+vec2(.3)).rgb;
    float fiber=(grain.r-grain.g)*.15+(grain.r-.75)*.055;
    vec3 paper=paper_color.rgb+edge*.085-shade*.18+fiber;
    float shadow=(contact*.30+cast*.24)*(1.0-mask);
    float alpha=mask+shadow;
    COLOR=vec4(mix(vec3(.035,.06,.065),paper,mask/max(alpha,.001)),alpha);
}
