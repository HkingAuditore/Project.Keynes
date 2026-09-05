#include "runtime_climate_formulas.h"
#include <iostream>
int main(){std::cout<<pk::climate_formula::smoothstep(pk::climate_formula::ICE_TEMP_HIGH,pk::climate_formula::ICE_TEMP_LOW,0.30f)<<" "<<pk::climate_formula::surface_absorbed_factor(false,0.30f)<<"\n";}
