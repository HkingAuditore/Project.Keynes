# -*- coding: utf-8 -*-
import pandas as pd, numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager
import os, glob

# Chinese font
for fp in [r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\simhei.ttf", r"C:\Windows\Fonts\simsun.ttc"]:
    if os.path.exists(fp):
        font_manager.fontManager.addfont(fp)
        matplotlib.rcParams["font.family"] = font_manager.FontProperties(fname=fp).get_name()
        break
matplotlib.rcParams["axes.unicode_minus"] = False

# dark theme
BG="#0f1419"; PANEL="#1a2029"; FG="#e6e6e6"; GRID="#2b3542"
RED="#ff5252"; GRN="#4caf50"; BLU="#42a5f5"; ORG="#ffa726"; PUR="#ab47bc"; CYN="#26c6da"; YEL="#ffee58"
plt.rcParams.update({"figure.facecolor":BG,"axes.facecolor":PANEL,"savefig.facecolor":BG,
    "text.color":FG,"axes.labelcolor":FG,"xtick.color":FG,"ytick.color":FG,
    "axes.edgecolor":GRID,"grid.color":GRID,"axes.titlecolor":FG})

BASE="economy_record_20260716_162646_v5_cell501_q15_r12_"
Q16=65536.0; MONEY=10000.0
coh=pd.read_csv(BASE+"cohorts.csv"); summ=pd.read_csv(BASE+"summary.csv")
bld=pd.read_csv(BASE+"buildings.csv"); mkt=pd.read_csv(BASE+"market.csv"); res=pd.read_csv(BASE+"resources.csv")
for df in (coh,summ,bld,mkt,res): df.columns=[c.lstrip('\ufeff') for c in df.columns]
OUT="charts"; os.makedirs(OUT,exist_ok=True)

def style(ax):
    ax.grid(True,alpha=.25,lw=.6); [s.set_color(GRID) for s in ax.spines.values()]

# ---- Chart 1: unemployment + population ----
t=coh.groupby('day_index').agg(popn=('population','sum'),owner=('owner_employed','sum'),
   emp=('employee_employed','sum'),unemp=('unemployed','sum')).reset_index()
fig,ax=plt.subplots(figsize=(9,4.2))
ax.stackplot(t.day_index,t.owner,t.emp,t.unemp,labels=['业主就业','雇员就业','失业'],
   colors=[GRN,BLU,RED],alpha=.85)
ax.plot(t.day_index,t.popn,color=YEL,lw=1.4,ls='--',label='总人口')
ax.set_title("人口就业结构（雇员就业恒为0，失业率约43%）",fontsize=12,fontweight='bold')
ax.set_xlabel("模拟天数"); ax.set_ylabel("人口"); ax.legend(loc='center right',facecolor=PANEL,edgecolor=GRID,fontsize=8)
ax.set_ylim(0,240); style(ax); fig.tight_layout(); fig.savefig(f"{OUT}/01_employment.png",dpi=130); plt.close()

# ---- Chart 2: funds accumulation total ----
f=coh.groupby('day_index')['funds'].sum().reset_index(); f['funds_m']=f.funds/MONEY/1e6
fig,ax=plt.subplots(figsize=(9,4.2))
ax.fill_between(f.day_index,f.funds_m,color=ORG,alpha=.25)
ax.plot(f.day_index,f.funds_m,color=ORG,lw=2)
ax.set_title("居民总存款持续单调膨胀（货币不断被净注入）",fontsize=12,fontweight='bold')
ax.set_xlabel("模拟天数"); ax.set_ylabel("总存款（百万¥）"); style(ax)
fig.tight_layout(); fig.savefig(f"{OUT}/02_funds.png",dpi=130); plt.close()

# ---- Chart 3: support money issued (money minting) ----
s=summ[['day_index','producer_support_money_issued','merchant_procurement_spent',
        'production_output_stock','production_output_supported']].copy()
s['issued_m']=s.producer_support_money_issued/MONEY/1e6
s['sup_ratio']=s.production_output_supported/s.production_output_stock*100
fig,ax=plt.subplots(figsize=(9,4.2))
ax.bar(s.day_index,s.issued_m,width=4,color=RED,alpha=.7,label='每周期铸币补贴（百万¥）')
ax2=ax.twinx(); ax2.plot(s.day_index,s.sup_ratio,color=CYN,lw=1.6,label='产出被补贴吸收比例%')
ax2.set_ylabel("补贴吸收比例 %",color=CYN); ax2.tick_params(colors=CYN); ax2.set_ylim(0,100)
ax.set_title("约78%的产出卖不掉，靠'生产者救济'铸币兜底",fontsize=12,fontweight='bold')
ax.set_xlabel("模拟天数"); ax.set_ylabel("铸币补贴（百万¥）",color=RED)
ax.legend(loc='upper left',facecolor=PANEL,edgecolor=GRID,fontsize=8)
style(ax); fig.tight_layout(); fig.savefig(f"{OUT}/03_subsidy.png",dpi=130); plt.close()

# ---- Chart 4: prices of active goods ----
active=['fish','gathered_plants','logs','processed_food','game_meat','fur','cloth','chipped_stone_tools']
fig,ax=plt.subplots(figsize=(9,4.6))
cols=[BLU,GRN,ORG,RED,PUR,CYN,YEL,'#ff80ab']
for gd,cc in zip(active,cols):
    sub=mkt[mkt.good_id==gd].groupby('day_index')['price'].mean()/MONEY
    ax.plot(sub.index,sub.values,label=gd,color=cc,lw=1.4)
ax.set_title("少数活跃商品价格：部分单调崩塌，个别失控暴涨",fontsize=12,fontweight='bold')
ax.set_xlabel("模拟天数"); ax.set_ylabel("价格（¥）"); ax.set_yscale('log')
ax.legend(loc='center left',bbox_to_anchor=(1.0,.5),facecolor=PANEL,edgecolor=GRID,fontsize=8)
style(ax); fig.tight_layout(); fig.savefig(f"{OUT}/04_prices.png",dpi=130); plt.close()

# ---- Chart 5: building operating states + suspended ----
b=bld[~bld.is_construction.astype(bool)]
os_=b.groupby(['day_index','operating_state']).size().unstack(fill_value=0)
fig,ax=plt.subplots(figsize=(9,4.2))
if 0 in os_: ax.plot(os_.index,os_[0],color=GRN,lw=1.6,label='正常运营')
if 1 in os_: ax.fill_between(os_.index,os_[1],color=RED,alpha=.5,label='因亏损停业(suspended)')
ax.set_title("建筑运营状态：长期约2-3个建筑组处于亏损停业",fontsize=12,fontweight='bold')
ax.set_xlabel("模拟天数"); ax.set_ylabel("建筑组数量"); ax.legend(facecolor=PANEL,edgecolor=GRID,fontsize=8)
style(ax); fig.tight_layout(); fig.savefig(f"{OUT}/05_buildings.png",dpi=130); plt.close()

# ---- Chart 6: funds per capita by class (inequality) ----
cl=coh.groupby(['day_index','profession_id']).agg(popn=('population','sum'),funds=('funds','sum')).reset_index()
cl['fpc']=cl.funds/cl.popn.replace(0,np.nan)/MONEY
fig,ax=plt.subplots(figsize=(9,4.2))
name={2:'职业2',8:'职业8',9:'职业9(业主)',12:'职业12',20:'职业20(半失业)',31:'职业31(全失业)'}
colr={2:CYN,8:GRN,9:ORG,12:PUR,20:BLU,31:RED}
for p in sorted(cl.profession_id.unique()):
    sub=cl[cl.profession_id==p]
    ax.plot(sub.day_index,sub.fpc,label=name.get(p,str(p)),color=colr.get(p,FG),lw=1.5)
ax.set_title("各职业人均存款：贫富分化拉大，失业者也在囤钱",fontsize=12,fontweight='bold')
ax.set_xlabel("模拟天数"); ax.set_ylabel("人均存款（¥）"); ax.legend(facecolor=PANEL,edgecolor=GRID,fontsize=8,ncol=2)
style(ax); fig.tight_layout(); fig.savefig(f"{OUT}/06_inequality.png",dpi=130); plt.close()

print("charts written:", sorted(glob.glob(f"{OUT}/*.png")))
