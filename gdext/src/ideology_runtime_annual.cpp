#include "ideology_runtime.h"
#include "annual_development_ledger.h"

namespace pk {
uint64_t NativeIdeologyRuntime::annual_draw_sequence(uint64_t handle) const {
    const auto *country=country_state_for(handle);return country?country->draw_sequence:0;
}
bool NativeIdeologyRuntime::grant_annual_points(uint64_t handle,int64_t points,
        uint64_t sequence,int64_t day,std::string &error){
    if(points<0||sequence==0){error="annual_reward_invalid";return false;}
    const auto seen=_producer_high_watermarks.find(ANNUAL_REWARD_PRODUCER);
    if(seen!=_producer_high_watermarks.end()&&static_cast<uint64_t>(seen->second)>=sequence)return true;
    Command cmd;cmd.opcode=GRANT_IDEOLOGY_POINTS;cmd.country_handle=handle;
    cmd.producer_id=ANNUAL_REWARD_PRODUCER;cmd.sequence=static_cast<int64_t>(sequence);
    cmd.value_q16=points;cmd.effective_day=day;
    if(!apply_command(cmd,day,error))return false;
    _producer_high_watermarks[ANNUAL_REWARD_PRODUCER]=static_cast<int64_t>(sequence);
    return true;
}
} // namespace pk
