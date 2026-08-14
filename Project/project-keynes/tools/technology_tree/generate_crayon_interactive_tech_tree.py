#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Generate the authoritative Crayon-style Interactive Technology Tree Topology Web Application.
Source of Truth: Project/project-keynes/data/technology/technology_network.json (Schema v3.0)
"""

import json
import base64
from pathlib import Path
from collections import defaultdict

ROOT = Path(__file__).resolve().parents[2]
NETWORK_PATH = ROOT / "data/technology/technology_network.json"
WORKSPACE_ROOT = Path(__file__).resolve().parents[3]
OUTPUT_HTML_PATH = ROOT / "tools/technology_tree/interactive_crayon_tech_tree.html"
DOCS_HTML_PATH = WORKSPACE_ROOT / "docs/interactive_crayon_tech_tree.html"

def build_html():
    print(f"Loading authoritative schema v3.0 data from {NETWORK_PATH}...")
    raw_data = json.loads(NETWORK_PATH.read_text(encoding="utf-8"))
    
    # Check assets
    assets_dir = WORKSPACE_ROOT / ".cursor/projects/d-Godot-ProjectKeynes-Project-Keynes/assets"
    knight_img = assets_dir / "c__Users_hkinghuang_AppData_Roaming_Cursor_User_workspaceStorage_empty-window_images_001_2001_0-2914a997-faf3-4e52-81fd-4457ee7b3185.png"
    shield_img = assets_dir / "c__Users_hkinghuang_AppData_Roaming_Cursor_User_workspaceStorage_empty-window_images_CA043BB302EFEFB3AC8950E20A11027C-d6ec180b-1d29-46d1-a431-19a40d491c9d.png"
    halberd_img = assets_dir / "c__Users_hkinghuang_AppData_Roaming_Cursor_User_workspaceStorage_empty-window_images_002_2005_1-6bf6234a-04ec-42d9-8a19-983f8266bbb6.png"
    
    knight_b64 = f"data:image/png;base64,{base64.b64encode(knight_img.read_bytes()).decode('ascii')}" if knight_img.exists() else ""
    shield_b64 = f"data:image/png;base64,{base64.b64encode(shield_img.read_bytes()).decode('ascii')}" if shield_img.exists() else ""
    halberd_b64 = f"data:image/png;base64,{base64.b64encode(halberd_img.read_bytes()).decode('ascii')}" if halberd_img.exists() else ""

    # Pass full data to JavaScript
    json_payload = json.dumps(raw_data, ensure_ascii=False)

    html_content = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Project Keynes · 权威科技树拓扑全景图谱 (Schema v3.0 蜡笔手绘交互版)</title>
<style>
  :root {{
    --bg-dark: #0f1013;
    --bg-darker: #090a0c;
    --bg-card: #201a14;
    --bg-parchment: #2c241b;
    --text-main: #f5eedc;
    --text-sub: #c4b69c;
    --text-muted: #807460;
    --border-paper: #eae1cc;
    
    /* Domain Crayon Colors */
    --color-agri: #64a852;
    --color-agri-bg: rgba(100, 168, 82, 0.16);
    --color-agri-glow: rgba(100, 168, 82, 0.45);
    
    --color-eng: #d98838;
    --color-eng-bg: rgba(217, 136, 56, 0.16);
    --color-eng-glow: rgba(217, 136, 56, 0.45);
    
    --color-sci: #4ba5db;
    --color-sci-bg: rgba(75, 165, 219, 0.16);
    --color-sci-glow: rgba(75, 165, 219, 0.45);
    
    --color-soc: #ca578b;
    --color-soc-bg: rgba(202, 87, 139, 0.16);
    --color-soc-glow: rgba(202, 87, 139, 0.45);

    --color-gold: #e5b84c;
    --color-milestone: #f05454;
    
    --font-serif: "Cinzel", "Songti SC", "Noto Serif SC", "SimSun", Georgia, serif;
    --font-sans: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
    --font-mono: "Fira Code", Consolas, Monaco, "Courier New", monospace;
  }}

  * {{
    box-sizing: border-box;
    margin: 0;
    padding: 0;
    user-select: none;
  }}

  body {{
    background-color: var(--bg-dark);
    color: var(--text-main);
    font-family: var(--font-sans);
    height: 100vh;
    width: 100vw;
    overflow: hidden;
    display: flex;
    flex-direction: column;
    background-image: 
      radial-gradient(circle at 15% 15%, rgba(217, 136, 56, 0.05) 0%, transparent 50%),
      radial-gradient(circle at 85% 85%, rgba(75, 165, 219, 0.05) 0%, transparent 50%),
      radial-gradient(circle at 50% 50%, rgba(202, 87, 139, 0.04) 0%, transparent 60%);
  }}

  /* ── 顶部中世纪蜡笔风格导航栏 ── */
  #header {{
    height: 72px;
    background: linear-gradient(180deg, #1c1611 0%, #120e0b 100%);
    border-bottom: 3px solid #2b2319;
    box-shadow: 0 6px 20px rgba(0, 0, 0, 0.8), inset 0 1px 0 rgba(255, 255, 255, 0.1);
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 18px;
    z-index: 100;
    flex-shrink: 0;
    gap: 16px;
  }}

  .brand-box {{
    display: flex;
    align-items: center;
    gap: 14px;
    flex-shrink: 0;
  }}

  .shield-icon {{
    width: 52px;
    height: 52px;
    background: url('{shield_b64}') center/contain no-repeat;
    filter: drop-shadow(0 2px 8px rgba(0,0,0,0.6));
    animation: pulse-subtle 4s infinite ease-in-out;
  }}

  @keyframes pulse-subtle {{
    0%, 100% {{ transform: scale(1); }}
    50% {{ transform: scale(1.04); }}
  }}

  .brand-text {{
    display: flex;
    flex-direction: column;
  }}

  .brand-title {{
    font-family: var(--font-serif);
    font-size: 19px;
    font-weight: 700;
    color: var(--color-gold);
    letter-spacing: 2px;
    text-shadow: 0 2px 6px rgba(0,0,0,0.8), 0 0 12px rgba(229, 184, 76, 0.3);
    display: flex;
    align-items: center;
    gap: 8px;
  }}

  .brand-badge {{
    font-size: 11px;
    background: #8b2626;
    color: #fff;
    padding: 2px 7px;
    border-radius: 4px;
    border: 1.5px solid #eae1cc;
    box-shadow: 0 2px 4px rgba(0,0,0,0.4);
    font-family: var(--font-mono);
  }}

  .brand-desc {{
    font-size: 11px;
    color: var(--text-muted);
    letter-spacing: 0.5px;
  }}

  /* 时代快速导航条 */
  .era-nav-container {{
    display: flex;
    align-items: center;
    gap: 4px;
    overflow-x: auto;
    padding: 4px 6px;
    background: rgba(0, 0, 0, 0.4);
    border: 1px solid #2a2218;
    border-radius: 8px;
    scrollbar-width: none;
  }}
  .era-nav-container::-webkit-scrollbar {{ display: none; }}

  .era-btn {{
    background: #1e1812;
    color: var(--text-sub);
    border: 1.5px solid #3d3121;
    border-radius: 6px;
    padding: 5px 9px;
    font-size: 11.5px;
    font-family: var(--font-serif);
    font-weight: 600;
    cursor: pointer;
    transition: all 0.2s ease;
    white-space: nowrap;
    display: flex;
    align-items: center;
    gap: 4px;
  }}

  .era-btn:hover {{
    background: #34281a;
    color: var(--color-gold);
    border-color: var(--color-gold);
    transform: translateY(-1px);
  }}

  .era-btn .era-dot {{
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--color-gold);
  }}

  /* 顶部右侧工具按钮组 */
  .header-actions {{
    display: flex;
    align-items: center;
    gap: 10px;
    flex-shrink: 0;
  }}

  .search-wrapper {{
    position: relative;
  }}

  .search-input {{
    background: #14100c;
    border: 2px solid #3a2e1d;
    border-radius: 20px;
    padding: 6px 14px 6px 32px;
    color: var(--text-main);
    font-size: 12px;
    width: 210px;
    outline: none;
    transition: all 0.25s ease;
  }}

  .search-input:focus {{
    border-color: var(--color-gold);
    width: 270px;
    background: #1b1510;
    box-shadow: 0 0 12px rgba(229, 184, 76, 0.25);
  }}

  .search-icon {{
    position: absolute;
    left: 10px;
    top: 50%;
    transform: translateY(-50%);
    color: var(--text-muted);
    font-size: 13px;
    pointer-events: none;
  }}

  .tool-btn {{
    background: #251d14;
    color: var(--text-sub);
    border: 1.5px solid #433320;
    border-radius: 6px;
    padding: 6px 12px;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
    display: flex;
    align-items: center;
    gap: 6px;
    transition: all 0.2s ease;
  }}

  .tool-btn:hover {{
    background: #392b1b;
    color: var(--text-main);
    border-color: var(--color-gold);
  }}

  /* ── 视图模式切换与领域筛选条 ── */
  #filter-bar {{
    height: 44px;
    background: #14100c;
    border-bottom: 1px solid #271f15;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 20px;
    font-size: 12px;
    z-index: 90;
    flex-shrink: 0;
    gap: 12px;
  }}

  .domain-filters {{
    display: flex;
    align-items: center;
    gap: 6px;
  }}

  .filter-chip {{
    display: flex;
    align-items: center;
    gap: 5px;
    padding: 3px 10px;
    border-radius: 14px;
    background: rgba(30, 24, 18, 0.7);
    border: 1.5px solid #382c1c;
    color: var(--text-sub);
    cursor: pointer;
    font-weight: 600;
    font-size: 11.5px;
    transition: all 0.2s ease;
  }}

  .filter-chip.agri.active {{
    background: var(--color-agri-bg);
    border-color: var(--color-agri);
    color: #a0f089;
    box-shadow: 0 0 8px var(--color-agri-glow);
  }}
  .filter-chip.eng.active {{
    background: var(--color-eng-bg);
    border-color: var(--color-eng);
    color: #ffb76b;
    box-shadow: 0 0 8px var(--color-eng-glow);
  }}
  .filter-chip.sci.active {{
    background: var(--color-sci-bg);
    border-color: var(--color-sci);
    color: #79d0ff;
    box-shadow: 0 0 8px var(--color-sci-glow);
  }}
  .filter-chip.soc.active {{
    background: var(--color-soc-bg);
    border-color: var(--color-soc);
    color: #ff8fc3;
    box-shadow: 0 0 8px var(--color-soc-glow);
  }}

  .edge-filters {{
    display: flex;
    align-items: center;
    gap: 6px;
  }}

  .edge-chip {{
    padding: 3px 8px;
    border-radius: 4px;
    background: #1a140e;
    border: 1px solid #332616;
    color: var(--text-muted);
    cursor: pointer;
    font-size: 11px;
    display: flex;
    align-items: center;
    gap: 5px;
    transition: all 0.15s;
  }}
  .edge-chip.active {{
    background: #3c2a16;
    color: var(--text-main);
    border-color: #87622f;
  }}

  .edge-dot {{
    width: 12px;
    height: 3px;
    border-radius: 2px;
  }}

  .stats-info {{
    color: var(--text-muted);
    font-size: 11px;
    font-family: var(--font-mono);
  }}

  /* ── 主画布工作区 ── */
  #main-viewport {{
    flex: 1;
    position: relative;
    overflow: hidden;
    cursor: grab;
    background: 
      linear-gradient(90deg, rgba(255,255,255,0.015) 1px, transparent 1px) 0 0 / 60px 60px,
      linear-gradient(0deg, rgba(255,255,255,0.015) 1px, transparent 1px) 0 0 / 60px 60px,
      #0e0f12;
  }}

  #main-viewport:active {{
    cursor: grabbing;
  }}

  #canvas-container {{
    position: absolute;
    left: 0;
    top: 0;
    transform-origin: 0 0;
    will-change: transform;
  }}

  /* 背景网格与泳道装饰 */
  #tree-svg-layer {{
    position: absolute;
    top: 0;
    left: 0;
    pointer-events: none;
    z-index: 5;
  }}

  /* 泳道背景与标头 */
  .swimlane-bg {{
    position: absolute;
    left: 0;
    width: 100%;
    border-bottom: 2px dashed rgba(255, 255, 255, 0.06);
    pointer-events: none;
  }}

  .swimlane-header-label {{
    position: absolute;
    left: 16px;
    display: flex;
    flex-direction: column;
    padding: 10px 16px;
    border-radius: 8px;
    border: 2px solid #eae1cc;
    background: rgba(22, 17, 12, 0.94);
    box-shadow: 0 4px 16px rgba(0,0,0,0.6);
    z-index: 10;
    pointer-events: auto;
  }}

  .swimlane-header-label h3 {{
    font-family: var(--font-serif);
    font-size: 16px;
    display: flex;
    align-items: center;
    gap: 8px;
  }}
  .swimlane-header-label p {{
    font-size: 11px;
    color: var(--text-muted);
    margin-top: 2px;
  }}

  /* 时代列标头 */
  .era-column-header {{
    position: absolute;
    top: 15px;
    display: flex;
    flex-direction: column;
    align-items: center;
    z-index: 15;
    pointer-events: auto;
  }}

  .era-crest {{
    width: 140px;
    padding: 8px 12px;
    background: linear-gradient(135deg, #2b2014 0%, #17110a 100%);
    border: 2.5px solid #eae1cc;
    border-radius: 8px;
    box-shadow: 0 6px 18px rgba(0,0,0,0.7), inset 0 0 10px rgba(229, 184, 76, 0.15);
    text-align: center;
    position: relative;
    cursor: pointer;
    transition: transform 0.2s, box-shadow 0.2s;
  }}

  .era-crest:hover {{
    transform: translateY(-3px) scale(1.03);
    border-color: var(--color-gold);
    box-shadow: 0 8px 24px rgba(229, 184, 76, 0.35);
  }}

  .era-crest .era-name {{
    font-family: var(--font-serif);
    font-size: 16px;
    font-weight: 700;
    color: var(--color-gold);
    letter-spacing: 1.5px;
  }}

  .era-crest .era-sub {{
    font-size: 10px;
    color: var(--text-muted);
    font-family: var(--font-mono);
    text-transform: uppercase;
  }}

  .era-crest .era-gate-badge {{
    margin-top: 4px;
    font-size: 10px;
    padding: 2px 6px;
    border-radius: 4px;
    background: rgba(240, 84, 84, 0.2);
    border: 1px solid rgba(240, 84, 84, 0.5);
    color: #ff9191;
  }}

  /* ── 粗犷蜡笔手绘剪纸节点卡片 (Paper Cutout Sticker Card) ── */
  .tech-node-card {{
    position: absolute;
    width: 216px;
    height: 98px;
    background: #241d15;
    border-radius: 8px;
    border: 2.5px solid #eae1cc; /* 粗白剪纸边框 */
    box-shadow: 
      0 6px 14px rgba(0, 0, 0, 0.7),
      inset 0 0 8px rgba(0, 0, 0, 0.3);
    padding: 8px 10px;
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    cursor: pointer;
    z-index: 20;
    transition: transform 0.18s ease, box-shadow 0.18s ease, border-color 0.18s ease, opacity 0.25s ease;
  }}

  .tech-node-card:hover {{
    transform: translateY(-4px) scale(1.035);
    z-index: 40;
    border-color: #ffffff;
    box-shadow: 
      0 12px 28px rgba(0, 0, 0, 0.85),
      0 0 16px rgba(234, 225, 204, 0.4);
  }}

  .tech-node-card.selected {{
    border-color: var(--color-gold);
    border-width: 3px;
    box-shadow: 
      0 0 0 2px #000,
      0 0 22px rgba(229, 184, 76, 0.7);
    z-index: 50;
    transform: translateY(-4px) scale(1.04);
  }}

  /* 领域专属蜡笔风格边条与色系 */
  .tech-node-card.agri {{
    border-left: 6px solid var(--color-agri);
  }}
  .tech-node-card.eng {{
    border-left: 6px solid var(--color-eng);
  }}
  .tech-node-card.sci {{
    border-left: 6px solid var(--color-sci);
  }}
  .tech-node-card.soc {{
    border-left: 6px solid var(--color-soc);
  }}

  /* 里程碑卡片：红白斜条纹质感 */
  .tech-node-card.is-milestone {{
    background: linear-gradient(135deg, #381919 0%, #201010 100%);
    border: 3px solid #f2dfba;
    border-left: 8px solid #e03b3b;
    box-shadow: 0 8px 20px rgba(224, 59, 59, 0.35);
  }}

  .tech-node-card.is-backbone {{
    background: linear-gradient(135deg, #2b2319 0%, #1c150e 100%);
    box-shadow: 0 6px 16px rgba(0,0,0,0.65), inset 0 0 12px rgba(229, 184, 76, 0.08);
  }}

  .card-top {{
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 6px;
  }}

  .card-title-group {{
    display: flex;
    flex-direction: column;
    min-width: 0;
  }}

  .card-title {{
    font-family: var(--font-serif);
    font-size: 13.5px;
    font-weight: 700;
    color: #fff;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }}

  .card-id {{
    font-size: 9px;
    color: var(--text-muted);
    font-family: var(--font-mono);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }}

  .card-icon-badge {{
    width: 26px;
    height: 26px;
    border-radius: 6px;
    background: #18130d;
    border: 1px solid #4a3c2a;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 13px;
    flex-shrink: 0;
  }}

  .card-mid {{
    display: flex;
    align-items: center;
    gap: 4px;
    flex-wrap: wrap;
    margin: 2px 0;
  }}

  .mini-tag {{
    font-size: 9px;
    padding: 1px 5px;
    border-radius: 3px;
    background: rgba(0,0,0,0.4);
    border: 1px solid rgba(255,255,255,0.1);
    color: var(--text-sub);
    white-space: nowrap;
  }}

  .mini-tag.unlock {{
    background: rgba(100, 168, 82, 0.2);
    border-color: rgba(100, 168, 82, 0.4);
    color: #b0f49c;
  }}

  .mini-tag.building {{
    background: rgba(217, 136, 56, 0.2);
    border-color: rgba(217, 136, 56, 0.4);
    color: #ffd096;
  }}

  .card-bottom {{
    display: flex;
    align-items: center;
    justify-content: space-between;
    font-size: 10px;
    color: var(--text-muted);
    border-top: 1px dashed rgba(255,255,255,0.08);
    padding-top: 3px;
  }}

  .card-cost {{
    font-family: var(--font-mono);
    color: var(--color-gold);
    font-weight: 600;
  }}

  .card-role-label {{
    font-size: 9.5px;
  }}

  /* 链路高亮虚化状态 */
  .tech-node-card.dimmed {{
    opacity: 0.12 !important;
    filter: grayscale(0.85);
    pointer-events: none;
  }}

  .tech-node-card.highlight-upstream {{
    border-color: #ffd24d !important;
    box-shadow: 0 0 20px rgba(255, 210, 77, 0.6) !important;
    opacity: 1 !important;
  }}

  .tech-node-card.highlight-downstream {{
    border-color: #58d8ff !important;
    box-shadow: 0 0 20px rgba(88, 216, 255, 0.6) !important;
    opacity: 1 !important;
  }}

  /* ── 拓扑连线样式 ── */
  .tech-edge {{
    fill: none;
    stroke-linecap: round;
    transition: opacity 0.25s ease, stroke-width 0.2s ease;
  }}

  .tech-edge.hard {{
    stroke: #725b3e;
    stroke-width: 2.2px;
  }}

  .tech-edge.application {{
    stroke: #4ba5db;
    stroke-width: 2px;
    stroke-dasharray: 6 3;
  }}

  .tech-edge.alternative {{
    stroke: #738ca6;
    stroke-width: 1.6px;
    stroke-dasharray: 3 3;
  }}

  .tech-edge.milestone_candidate {{
    stroke: #e5b84c;
    stroke-width: 1.8px;
    stroke-dasharray: 5 4;
  }}

  .tech-edge.dimmed {{
    opacity: 0.04 !important;
  }}

  .tech-edge.active-upstream {{
    stroke: #ffca36 !important;
    stroke-width: 3.5px !important;
    filter: drop-shadow(0 0 5px rgba(255, 202, 54, 0.7));
    opacity: 1 !important;
  }}

  .tech-edge.active-downstream {{
    stroke: #45c4ff !important;
    stroke-width: 3.5px !important;
    filter: drop-shadow(0 0 5px rgba(69, 196, 255, 0.7));
    opacity: 1 !important;
  }}

  /* ── 右侧手绘羊皮纸详情侧栏 (Detail Drawer) ── */
  #detail-drawer {{
    position: absolute;
    right: 0;
    top: 0;
    bottom: 0;
    width: 480px;
    background: linear-gradient(180deg, #221b14 0%, #16110c 100%);
    border-left: 3px solid #4a3924;
    box-shadow: -10px 0 35px rgba(0, 0, 0, 0.85);
    z-index: 120;
    transform: translateX(100%);
    transition: transform 0.28s cubic-bezier(0.16, 1, 0.3, 1);
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }}

  #detail-drawer.open {{
    transform: translateX(0);
  }}

  .drawer-header {{
    padding: 16px 20px;
    background: #18130e;
    border-bottom: 2px solid #362919;
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 12px;
  }}

  .drawer-close-btn {{
    background: #2b2014;
    border: 1.5px solid #584128;
    color: var(--text-sub);
    width: 32px;
    height: 32px;
    border-radius: 6px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    font-size: 16px;
    transition: all 0.15s;
    flex-shrink: 0;
  }}
  .drawer-close-btn:hover {{
    background: #46331e;
    color: #fff;
    border-color: var(--color-gold);
  }}

  .drawer-content {{
    flex: 1;
    overflow-y: auto;
    padding: 20px;
    display: flex;
    flex-direction: column;
    gap: 16px;
  }}

  .drawer-content::-webkit-scrollbar {{
    width: 7px;
  }}
  .drawer-content::-webkit-scrollbar-thumb {{
    background: #4a3721;
    border-radius: 4px;
  }}

  .section-box {{
    background: rgba(20, 15, 10, 0.65);
    border: 1.5px solid #36291a;
    border-radius: 8px;
    padding: 14px;
  }}

  .section-title {{
    font-family: var(--font-serif);
    font-size: 13px;
    font-weight: 700;
    color: var(--color-gold);
    margin-bottom: 8px;
    display: flex;
    align-items: center;
    gap: 6px;
    border-bottom: 1px dashed rgba(229, 184, 76, 0.2);
    padding-bottom: 4px;
  }}

  .relation-list {{
    display: flex;
    flex-direction: column;
    gap: 6px;
  }}

  .relation-item {{
    background: #2a2016;
    border: 1px solid #483622;
    border-radius: 5px;
    padding: 7px 10px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    cursor: pointer;
    font-size: 12px;
    transition: all 0.15s;
  }}
  .relation-item:hover {{
    background: #3e2d1d;
    border-color: var(--color-gold);
    transform: translateX(4px);
  }}

  /* ── 底部控制小工具 (Zoom HUD) ── */
  .zoom-hud {{
    position: absolute;
    bottom: 24px;
    left: 24px;
    background: rgba(24, 18, 12, 0.92);
    border: 2px solid #eae1cc;
    border-radius: 8px;
    padding: 6px 10px;
    display: flex;
    align-items: center;
    gap: 8px;
    box-shadow: 0 8px 24px rgba(0,0,0,0.8);
    z-index: 100;
  }}

  .hud-btn {{
    background: #2d2217;
    border: 1px solid #544028;
    color: var(--text-main);
    width: 28px;
    height: 28px;
    border-radius: 4px;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 14px;
    font-weight: bold;
    cursor: pointer;
    transition: all 0.15s;
  }}
  .hud-btn:hover {{
    background: #4a3621;
    border-color: var(--color-gold);
  }}

  .zoom-label {{
    font-size: 11px;
    font-family: var(--font-mono);
    color: var(--text-sub);
    min-width: 46px;
    text-align: center;
  }}

  /* 装饰插画贴纸 */
  .sticker-knight {{
    position: absolute;
    bottom: 16px;
    right: 24px;
    width: 140px;
    height: 140px;
    background: url('{knight_b64}') center/contain no-repeat;
    pointer-events: none;
    opacity: 0.85;
    filter: drop-shadow(0 4px 12px rgba(0,0,0,0.7));
    z-index: 80;
    transition: opacity 0.3s;
  }}

  #detail-drawer.open ~ .sticker-knight {{
    opacity: 0.15;
  }}

  /* 搜索下拉结果 */
  #search-results-dropdown {{
    position: absolute;
    top: 60px;
    right: 180px;
    width: 340px;
    max-height: 420px;
    overflow-y: auto;
    background: #1e1710;
    border: 2px solid var(--color-gold);
    border-radius: 8px;
    box-shadow: 0 10px 30px rgba(0,0,0,0.9);
    z-index: 200;
    display: none;
  }}

  .search-res-item {{
    padding: 8px 12px;
    border-bottom: 1px solid #332719;
    cursor: pointer;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }}
  .search-res-item:hover {{
    background: #392b1b;
  }}

  .search-res-name {{
    font-weight: bold;
    color: var(--color-gold);
    font-size: 13px;
  }}
  .search-res-meta {{
    font-size: 11px;
    color: var(--text-muted);
  }}
</style>
</head>
<body>

<!-- 顶部主标题与时代快捷导航栏 -->
<header id="header">
  <div class="brand-box">
    <div class="shield-icon" title="Project Keynes 皇家科技树徽章"></div>
    <div class="brand-text">
      <div class="brand-title">
        PROJECT KEYNES
        <span class="brand-badge">Schema v3.0 权威数据</span>
      </div>
      <div class="brand-desc">361 节点 · 11 时代 · 4 领域 · 1108 拓扑边 · 蜡笔剪纸交互图谱</div>
    </div>
  </div>

  <div class="era-nav-container" id="era-nav-bar">
    <!-- 动态渲染 11 个时代的快捷导航按钮 -->
  </div>

  <div class="header-actions">
    <div class="search-wrapper">
      <span class="search-icon">🔍</span>
      <input type="text" id="tech-search" class="search-input" placeholder="搜索科技/物资/建筑/资源..." autocomplete="off">
    </div>
    <button class="tool-btn" id="btn-fit-all" title="全屏自适应">📐 适应视口</button>
    <button class="tool-btn" id="btn-reset-zoom" title="重置视角">↺ 重置</button>
  </div>
</header>

<!-- 搜索结果下拉面板 -->
<div id="search-results-dropdown"></div>

<!-- 筛选与控制栏 -->
<div id="filter-bar">
  <div class="domain-filters">
    <span style="color: var(--text-muted); font-size: 11px; margin-right: 2px;">领域泳道:</span>
    <div class="filter-chip agri active" data-domain="agriculture">🌾 农业</div>
    <div class="filter-chip eng active" data-domain="engineering">⚙️ 工程</div>
    <div class="filter-chip sci active" data-domain="science">🔭 科学</div>
    <div class="filter-chip soc active" data-domain="society">🏛️ 社会</div>
  </div>

  <div class="edge-filters">
    <span style="color: var(--text-muted); font-size: 11px; margin-right: 2px;">拓扑边显示:</span>
    <div class="edge-chip active" data-kind="hard">
      <span class="edge-dot" style="background: #a38258;"></span> 硬前置 (303)
    </div>
    <div class="edge-chip active" data-kind="milestone_candidate">
      <span class="edge-dot" style="background: #e5b84c;"></span> 时代候选 (88)
    </div>
    <div class="edge-chip active" data-kind="application">
      <span class="edge-dot" style="background: #4ba5db;"></span> 应用交汇 (19)
    </div>
    <div class="edge-chip active" data-kind="alternative">
      <span class="edge-dot" style="background: #738ca6;"></span> 替代路线 (698)
    </div>
  </div>

  <div class="stats-info" id="stats-banner">
    361 项科技 · 1108 条拓扑边
  </div>
</div>

<!-- 主视口与画布容器 -->
<main id="main-viewport">
  <div id="canvas-container">
    <!-- 背景泳道和标头由 JS 动态生成 -->
    <div id="lanes-layer"></div>
    
    <!-- SVG 连线层 -->
    <svg id="tree-svg-layer">
      <defs>
        <marker id="arrow-hard" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
          <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#8c704c" />
        </marker>
        <marker id="arrow-upstream" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
          <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#ffca36" />
        </marker>
        <marker id="arrow-downstream" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
          <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#45c4ff" />
        </marker>
      </defs>
      <g id="svg-edges-group"></g>
    </svg>

    <!-- 节点卡片 DOM 层 -->
    <div id="nodes-layer"></div>
  </div>

  <!-- 缩放与居中 HUD -->
  <div class="zoom-hud">
    <button class="hud-btn" id="btn-zoom-in" title="放大 (滚轮向上)">+</button>
    <button class="hud-btn" id="btn-zoom-out" title="缩小 (滚轮向下)">-</button>
    <div class="zoom-label" id="zoom-text">100%</div>
  </div>

  <!-- 装饰贴纸 -->
  <div class="sticker-knight" title="Project Keynes 骑士手绘贴纸"></div>
</main>

<!-- 科技详情右侧抽屉 -->
<aside id="detail-drawer">
  <div class="drawer-header">
    <div style="display: flex; flex-direction: column; min-width: 0;">
      <span id="detail-domain-tag" style="font-size: 11px; font-weight: bold; color: var(--color-gold);">农业领域 · 石器时代</span>
      <h2 id="detail-title" style="font-family: var(--font-serif); font-size: 20px; color: #fff; margin-top: 2px;">狩猎</h2>
      <span id="detail-id" style="font-size: 11px; color: var(--text-muted); font-family: var(--font-mono);">tech.hunting</span>
    </div>
    <button class="drawer-close-btn" id="btn-close-drawer" title="关闭 (Esc)">✕</button>
  </div>

  <div class="drawer-content">
    <div class="section-box">
      <div class="section-title">📊 研发概况与机会成本</div>
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; font-size: 12px;">
        <div>研发消耗: <b id="detail-cost" style="color: var(--color-gold); font-family: var(--font-mono);">0 科技点</b></div>
        <div>网络角色: <b id="detail-network-role">分支节点 (Branch)</b></div>
        <div>节点角色: <b id="detail-node-role">处理 (Handling)</b></div>
        <div>开局类型: <b id="detail-starter">开局直接授予</b></div>
      </div>
      <div id="detail-opp-cost" style="font-size: 11px; color: var(--text-muted); margin-top: 8px; border-top: 1px dashed rgba(255,255,255,0.06); padding-top: 6px;"></div>
    </div>

    <div class="section-box" id="detail-reveal-box">
      <div class="section-title">🔍 发现启发 (Reveal Condition)</div>
      <div id="detail-reveal-content" style="font-size: 12px; color: var(--text-sub); line-height: 1.5;">
        需发现资源信号「野生动物 (resource.wild_game)」
      </div>
    </div>

    <div class="section-box" id="detail-routes-box">
      <div class="section-title">🛣️ 研发路线 (Research Routes)</div>
      <div id="detail-routes-list" style="display: flex; flex-direction: column; gap: 6px; font-size: 12px;">
        <!-- 动态填充 -->
      </div>
    </div>

    <div class="section-box" id="detail-unlocks-box">
      <div class="section-title">🎁 权威内容解锁 (Content Unlocks)</div>
      <div id="detail-unlocks-list" style="display: flex; flex-direction: column; gap: 6px; font-size: 12px;">
        <!-- 动态填充 -->
      </div>
    </div>

    <div class="section-box" id="detail-modifiers-box">
      <div class="section-title">⚡ 永久数值修正 (Modifiers)</div>
      <div id="detail-modifiers-list" style="font-size: 12px; color: var(--text-sub);">
        无永久 Modifier
      </div>
    </div>

    <div class="section-box">
      <div class="section-title">⬅️ 硬前置科技 (Prerequisites)</div>
      <div class="relation-list" id="detail-prereqs-list">
        <!-- 动态填充 -->
      </div>
    </div>

    <div class="section-box">
      <div class="section-title">➡️ 解锁后继科技 (Unlocks Successors)</div>
      <div class="relation-list" id="detail-successors-list">
        <!-- 动态填充 -->
      </div>
    </div>
  </div>
</aside>

<script>
  // 注入服务端权威 Schema v3.0 数据
  const RAW = {json_payload};

  const DOMAIN_ICONS = {{
    "agriculture": "🌾",
    "engineering": "⚙️",
    "science": "🔭",
    "society": "🏛️"
  }};

  const DOMAIN_COLORS = {{
    "agriculture": "var(--color-agri)",
    "engineering": "var(--color-eng)",
    "science": "var(--color-sci)",
    "society": "var(--color-soc)"
  }};

  const nodeMap = new Map();
  RAW.nodes.forEach(n => nodeMap.set(n.id, n));
  
  const eraMap = new Map();
  RAW.eras.forEach((e, idx) => {{ e.index = idx; eraMap.set(e.id, e); }});

  const domainMap = new Map();
  RAW.domains.forEach((d, idx) => {{ d.index = idx; domainMap.set(d.id, d); }});

  // 建立双向图索引
  const hardSuccessors = new Map();
  const allSuccessors = new Map();
  RAW.nodes.forEach(n => {{
    hardSuccessors.set(n.id, []);
    allSuccessors.set(n.id, []);
  }});

  (RAW.visual_edges || []).forEach(edge => {{
    if (!allSuccessors.has(edge.from)) allSuccessors.set(edge.from, []);
    allSuccessors.get(edge.from).push(edge);
    if (edge.kind === "hard") {{
      if (!hardSuccessors.has(edge.from)) hardSuccessors.set(edge.from, []);
      hardSuccessors.get(edge.from).push(edge.to);
    }}
  }});

  // 坐标布局常数
  const ERA_WIDTH = 580;         // 每时代列宽
  const LANE_HEIGHT = 440;       // 每泳道高度
  const NODE_WIDTH = 216;
  const NODE_HEIGHT = 98;
  const LEFT_OFFSET = 260;       // 左侧泳道标题栏间距
  const TOP_OFFSET = 120;        // 顶部时代标头间距

  const nodePositions = new Map();

  function calculateLayout() {{
    const buckets = new Map();
    RAW.nodes.forEach(node => {{
      const key = `${{node.era_id}}_${{node.domain_id}}`;
      if (!buckets.has(key)) buckets.set(key, []);
      buckets.get(key).push(node);
    }});

    RAW.eras.forEach(era => {{
      RAW.domains.forEach(domain => {{
        const key = `${{era.id}}_${{domain.id}}`;
        const list = buckets.get(key) || [];
        if (list.length === 0) return;

        // 分类排序：主干与开局优先，再是里程碑，再是普通分支
        const backboneNodes = list.filter(n => n.network_role === "backbone" || n.is_starting);
        const milestoneNodes = list.filter(n => n.is_milestone);
        const branchNodes = list.filter(n => n.network_role !== "backbone" && !n.is_milestone && !n.is_starting);

        const baseX = LEFT_OFFSET + era.index * ERA_WIDTH + 30;
        const baseY = TOP_OFFSET + domain.index * LANE_HEIGHT + 30;

        const allSorted = [...backboneNodes, ...milestoneNodes, ...branchNodes];
        const cols = 2;
        const colWidth = 265;
        const rowHeight = 118;

        allSorted.forEach((node, idx) => {{
          const c = idx % cols;
          const r = Math.floor(idx / cols);
          
          let x = baseX + c * colWidth;
          let y = baseY + r * rowHeight;

          if (node.is_milestone) {{
            x = baseX + (ERA_WIDTH - NODE_WIDTH) / 2 - 10;
            y = baseY + 10;
          }}

          nodePositions.set(node.id, {{ x, y, width: NODE_WIDTH, height: NODE_HEIGHT }});
        }});
      }});
    }});
  }}

  function renderLanesAndEras() {{
    const lanesLayer = document.getElementById("lanes-layer");
    const totalWidth = LEFT_OFFSET + RAW.eras.length * ERA_WIDTH + 200;
    const totalHeight = TOP_OFFSET + RAW.domains.length * LANE_HEIGHT + 100;

    const svgLayer = document.getElementById("tree-svg-layer");
    svgLayer.setAttribute("width", totalWidth);
    svgLayer.setAttribute("height", totalHeight);

    let html = "";
    RAW.domains.forEach((dom, idx) => {{
      const top = TOP_OFFSET + idx * LANE_HEIGHT;
      html += `
        <div class="swimlane-bg" style="top: ${{top}}px; height: ${{LANE_HEIGHT}}px;"></div>
        <div class="swimlane-header-label" style="top: ${{top + 30}}px; border-left: 8px solid ${{DOMAIN_COLORS[dom.id]}};">
          <h3 style="color: ${{DOMAIN_COLORS[dom.id]}};">
            ${{DOMAIN_ICONS[dom.id]}} ${{dom.display_name}}领域
          </h3>
          <p>核心主干 · 知识与生产演进泳道</p>
        </div>
      `;
    }});

    RAW.eras.forEach(era => {{
      const left = LEFT_OFFSET + era.index * ERA_WIDTH + 30;
      html += `
        <div class="era-column-header" style="left: ${{left}}px; width: ${{ERA_WIDTH - 60}}px;">
          <div class="era-crest" onclick="scrollToEra('${{era.id}}')">
            <div class="era-name">${{era.display_name}}</div>
            <div class="era-sub">${{era.id}} ERA</div>
            <div class="era-gate-badge">👑 8 选 4 里程碑解锁</div>
          </div>
        </div>
      `;
    }});

    lanesLayer.innerHTML = html;
  }}

  function renderNodeCards() {{
    const nodesLayer = document.getElementById("nodes-layer");
    let html = "";

    RAW.nodes.forEach(node => {{
      const pos = nodePositions.get(node.id);
      if (!pos) return;

      const domClass = node.domain_id.substring(0, 3);
      const icon = DOMAIN_ICONS[node.domain_id] || "📜";

      let roleLabel = "分支";
      if (node.network_role === "backbone") roleLabel = "🌟 核心主干";
      if (node.is_milestone) roleLabel = "👑 时代里程碑";
      if (node.is_starting) roleLabel = "🌱 开局直接";

      const milestoneClass = node.is_milestone ? "is-milestone" : "";
      const backboneClass = node.network_role === "backbone" ? "is-backbone" : "";

      let unlockTags = "";
      if (node.content_effects && node.content_effects.length > 0) {{
        node.content_effects.slice(0, 2).forEach(eff => {{
          unlockTags += `<span class="mini-tag unlock">${{eff.display_name || eff.id}}</span>`;
        }});
      }}

      html += `
        <div class="tech-node-card ${{domClass}} ${{milestoneClass}} ${{backboneClass}}" 
             id="node-${{node.id.replace(/\\./g, '_')}}"
             data-id="${{node.id}}"
             data-domain="${{node.domain_id}}"
             data-role="${{node.network_role}}"
             data-era="${{node.era_id}}"
             style="left: ${{pos.x}}px; top: ${{pos.y}}px;"
             onclick="selectNode('${{node.id}}')">
          <div class="card-top">
            <div class="card-title-group">
              <div class="card-title" title="${{node.display_name}}">${{node.display_name}}</div>
              <div class="card-id">${{node.id}}</div>
            </div>
            <div class="card-icon-badge">${{icon}}</div>
          </div>

          <div class="card-mid">
            ${{unlockTags}}
          </div>

          <div class="card-bottom">
            <span class="card-cost">${{node.cost_points.toLocaleString()}} 点</span>
            <span class="card-role-label">${{roleLabel}}</span>
          </div>
        </div>
      `;
    }});

    nodesLayer.innerHTML = html;
  }}

  function renderEdges() {{
    const group = document.getElementById("svg-edges-group");
    let svgHtml = "";

    (RAW.visual_edges || []).forEach(edge => {{
      const srcPos = nodePositions.get(edge.from);
      const targetPos = nodePositions.get(edge.to);
      if (!srcPos || !targetPos) return;

      const x1 = srcPos.x + srcPos.width;
      const y1 = srcPos.y + srcPos.height / 2;
      const x2 = targetPos.x;
      const y2 = targetPos.y + targetPos.height / 2;

      const dx = Math.max(40, (x2 - x1) * 0.5);
      const pathD = `M ${{x1}} ${{y1}} C ${{x1 + dx}} ${{y1}}, ${{x2 - dx}} ${{y2}}, ${{x2}} ${{y2}}`;

      const edgeId = `edge-${{edge.from.replace(/\\./g, '_')}}-${{edge.to.replace(/\\./g, '_')}}`;

      svgHtml += `
        <path id="${{edgeId}}"
              class="tech-edge ${{edge.kind}}"
              data-source="${{edge.from}}"
              data-target="${{edge.to}}"
              data-kind="${{edge.kind}}"
              d="${{pathD}}"
              marker-end="url(#arrow-hard)" />
      `;
    }});

    group.innerHTML = svgHtml;
  }}

  function renderEraNav() {{
    const nav = document.getElementById("era-nav-bar");
    let html = "";
    RAW.eras.forEach(era => {{
      html += `
        <button class="era-btn" onclick="scrollToEra('${{era.id}}')">
          <span class="era-dot"></span>
          ${{era.display_name}}
        </button>
      `;
    }});
    nav.innerHTML = html;
  }}

  // ── 缩放与平移 ──
  let zoom = 0.85;
  let panX = 40;
  let panY = 20;
  let isDragging = false;
  let startX, startY;

  const viewport = document.getElementById("main-viewport");
  const container = document.getElementById("canvas-container");
  const zoomText = document.getElementById("zoom-text");

  function updateTransform() {{
    container.style.transform = `translate(${{panX}}px, ${{panY}}px) scale(${{zoom}})`;
    zoomText.innerText = `${{Math.round(zoom * 100)}}%`;
  }}

  viewport.addEventListener("mousedown", e => {{
    if (e.target.closest(".tech-node-card") || e.target.closest(".era-crest") || e.target.closest(".zoom-hud")) return;
    isDragging = true;
    startX = e.clientX - panX;
    startY = e.clientY - panY;
  }});

  window.addEventListener("mousemove", e => {{
    if (!isDragging) return;
    panX = e.clientX - startX;
    panY = e.clientY - startY;
    updateTransform();
  }});

  window.addEventListener("mouseup", () => {{
    isDragging = false;
  }});

  viewport.addEventListener("wheel", e => {{
    e.preventDefault();
    const rect = viewport.getBoundingClientRect();
    const mouseX = e.clientX - rect.left;
    const mouseY = e.clientY - rect.top;

    const delta = e.deltaY < 0 ? 1.15 : 0.87;
    const newZoom = Math.min(Math.max(0.18, zoom * delta), 2.8);

    panX = mouseX - (mouseX - panX) * (newZoom / zoom);
    panY = mouseY - (mouseY - panY) * (newZoom / zoom);
    zoom = newZoom;
    updateTransform();
  }}, {{ passive: false }});

  document.getElementById("btn-zoom-in").onclick = () => {{
    zoom = Math.min(2.8, zoom * 1.2);
    updateTransform();
  }};

  document.getElementById("btn-zoom-out").onclick = () => {{
    zoom = Math.max(0.18, zoom / 1.2);
    updateTransform();
  }};

  document.getElementById("btn-reset-zoom").onclick = () => {{
    zoom = 0.85;
    panX = 40;
    panY = 20;
    updateTransform();
  }};

  document.getElementById("btn-fit-all").onclick = () => {{
    const totalWidth = LEFT_OFFSET + RAW.eras.length * ERA_WIDTH + 200;
    const vWidth = viewport.clientWidth;
    zoom = Math.max(0.18, (vWidth / totalWidth) * 0.95);
    panX = 20;
    panY = 10;
    updateTransform();
  }};

  function scrollToEra(eraId) {{
    const era = eraMap.get(eraId);
    if (!era) return;
    const targetX = LEFT_OFFSET + era.index * ERA_WIDTH;
    panX = -targetX * zoom + viewport.clientWidth * 0.25;
    panY = 20;
    updateTransform();
  }}

  // ── 科技节点选择、依赖双向链追踪与高亮 ──
  let selectedNodeId = null;

  function selectNode(nodeId, shouldScroll = false) {{
    const node = nodeMap.get(nodeId);
    if (!node) return;
    selectedNodeId = nodeId;

    document.querySelectorAll(".tech-node-card").forEach(el => {{
      el.classList.remove("selected", "highlight-upstream", "highlight-downstream", "dimmed");
    }});
    document.querySelectorAll(".tech-edge").forEach(el => {{
      el.classList.remove("active-upstream", "active-downstream", "dimmed");
      el.setAttribute("marker-end", "url(#arrow-hard)");
    }});

    // 1. 递归查找所有硬前置与关联
    const upstreamNodes = new Set();
    const upstreamEdges = new Set();
    const queueUp = [nodeId];

    while (queueUp.length > 0) {{
      const curr = queueUp.shift();
      const currNode = nodeMap.get(curr);
      if (!currNode) continue;
      (currNode.hard_prerequisite_ids || []).forEach(pId => {{
        upstreamEdges.add(`${{pId}}->${{curr}}`);
        if (!upstreamNodes.has(pId)) {{
          upstreamNodes.add(pId);
          queueUp.push(pId);
        }}
      }});
    }}

    // 2. 递归查找所有后继
    const downstreamNodes = new Set();
    const downstreamEdges = new Set();
    const queueDown = [nodeId];

    while (queueDown.length > 0) {{
      const curr = queueDown.shift();
      const succList = hardSuccessors.get(curr) || [];
      succList.forEach(sId => {{
        downstreamEdges.add(`${{curr}}->${{sId}}`);
        if (!downstreamNodes.has(sId)) {{
          downstreamNodes.add(sId);
          queueDown.push(sId);
        }}
      }});
    }}

    document.querySelectorAll(".tech-node-card").forEach(el => {{
      const id = el.dataset.id;
      if (id === nodeId) {{
        el.classList.add("selected");
      }} else if (upstreamNodes.has(id)) {{
        el.classList.add("highlight-upstream");
      }} else if (downstreamNodes.has(id)) {{
        el.classList.add("highlight-downstream");
      }} else {{
        el.classList.add("dimmed");
      }}
    }});

    document.querySelectorAll(".tech-edge").forEach(el => {{
      const s = el.dataset.source;
      const t = el.dataset.target;
      const key = `${{s}}->${{t}}`;

      if (upstreamEdges.has(key)) {{
        el.classList.add("active-upstream");
        el.setAttribute("marker-end", "url(#arrow-upstream)");
      }} else if (downstreamEdges.has(key)) {{
        el.classList.add("active-downstream");
        el.setAttribute("marker-end", "url(#arrow-downstream)");
      }} else {{
        el.classList.add("dimmed");
      }}
    }});

    populateDetailDrawer(node);
    document.getElementById("detail-drawer").classList.add("open");

    if (shouldScroll) {{
      const pos = nodePositions.get(nodeId);
      if (pos) {{
        panX = -pos.x * zoom + viewport.clientWidth / 2 - (pos.width * zoom) / 2;
        panY = -pos.y * zoom + viewport.clientHeight / 2 - (pos.height * zoom) / 2;
        updateTransform();
      }}
    }}
  }}

  function clearSelection() {{
    selectedNodeId = null;
    document.querySelectorAll(".tech-node-card").forEach(el => {{
      el.classList.remove("selected", "highlight-upstream", "highlight-downstream", "dimmed");
    }});
    document.querySelectorAll(".tech-edge").forEach(el => {{
      el.classList.remove("active-upstream", "active-downstream", "dimmed");
      el.setAttribute("marker-end", "url(#arrow-hard)");
    }});
    document.getElementById("detail-drawer").classList.remove("open");
  }}

  function populateDetailDrawer(node) {{
    const era = eraMap.get(node.era_id);
    const domain = domainMap.get(node.domain_id);

    document.getElementById("detail-title").innerText = node.display_name;
    document.getElementById("detail-id").innerText = node.id;
    document.getElementById("detail-domain-tag").innerText = `${{domain ? domain.display_name : ""}}领域 · ${{era ? era.display_name : ""}}`;
    document.getElementById("detail-domain-tag").style.color = DOMAIN_COLORS[node.domain_id];
    document.getElementById("detail-cost").innerText = `${{node.cost_points.toLocaleString()}} 科技点`;
    document.getElementById("detail-era").innerText = era ? era.display_name : node.era_id;
    document.getElementById("detail-network-role").innerText = node.network_role === "backbone" ? "公共主干 (Backbone)" : (node.is_milestone ? "时代里程碑 (Milestone)" : "分支节点 (Branch)");
    document.getElementById("detail-node-role").innerText = node.node_role || "handling";
    document.getElementById("detail-starter").innerText = node.is_starting ? "开局直接授予" : (node.is_starter_eligible ? "区域开局候选" : "常规研发");

    document.getElementById("detail-opp-cost").innerText = node.opportunity_cost ? `⚖️ 机会成本: ${{node.opportunity_cost}}` : "";

    // 发现启发
    const revealBox = document.getElementById("detail-reveal-content");
    if (node.reveal_summary) {{
      revealBox.innerText = node.reveal_summary;
    }} else if (node.reveal_condition) {{
      revealBox.innerText = `需要观测到证据信号: ${{node.reveal_condition.id || JSON.stringify(node.reveal_condition)}}`;
    }} else {{
      revealBox.innerText = "开局自动揭示 / 无特殊启发条件";
    }}

    // 研发路线
    const routesBox = document.getElementById("detail-routes-list");
    let routeHtml = "";
    if (node.research_routes && node.research_routes.length > 0) {{
      node.research_routes.forEach((r, idx) => {{
        routeHtml += `
          <div style="background: #2a2016; padding: 6px 10px; border-radius: 4px; border: 1px solid #443420;">
            <b style="color: var(--color-gold);">路线 ${{idx + 1}}:</b> ${{r.summary || r.id || "条件包"}}
          </div>
        `;
      }});
    }} else if (node.secondary_route_tags && node.secondary_route_tags.length > 0) {{
      routeHtml = node.secondary_route_tags.map(t => `<div class="mini-tag">${{t}}</div>`).join(" ");
    }} else {{
      routeHtml = "<span style='color: var(--text-muted);'>无额外研究路线要求</span>";
    }}
    routesBox.innerHTML = routeHtml;

    // 解锁内容
    const unlocksList = document.getElementById("detail-unlocks-list");
    let unlockHtml = "";
    if (node.content_effects && node.content_effects.length > 0) {{
      node.content_effects.forEach(eff => {{
        const kindLabel = eff.kind === "good" ? "物资" : (eff.kind === "building" ? "建筑" : "资源");
        unlockHtml += `
          <div style="background: #2a2016; padding: 6px 10px; border-radius: 4px; border: 1px solid #443420;">
            <b style="color: var(--color-gold);">[${{kindLabel}}]</b> ${{eff.display_name || eff.id}}
            <span style="font-size: 10px; color: var(--text-muted); float: right;">${{eff.attribute}}</span>
          </div>
        `;
      }});
    }} else {{
      unlockHtml = "<span style='color: var(--text-muted);'>无直接内容解锁</span>";
    }}
    unlocksList.innerHTML = unlockHtml;

    // Modifiers
    const modBox = document.getElementById("detail-modifiers-list");
    if (node.modifier_terms && node.modifier_terms.length > 0) {{
      let modHtml = "";
      node.modifier_terms.forEach(m => {{
        modHtml += `<div>• ${{m.term_id || m.target_attribute || JSON.stringify(m)}}</div>`;
      }});
      modBox.innerHTML = modHtml;
    }} else {{
      modBox.innerHTML = "无永久 Modifier 条款";
    }}

    // 前置科技列表 (含理由)
    const prereqsList = document.getElementById("detail-prereqs-list");
    let prereqHtml = "";
    (node.hard_prerequisite_ids || []).forEach(pId => {{
      const pNode = nodeMap.get(pId);
      const rationale = (node.prerequisite_rationales || {{}})[pId] || "";
      prereqHtml += `
        <div class="relation-item" onclick="selectNode('${{pId}}', true)">
          <div style="display: flex; flex-direction: column;">
            <span style="font-weight: 600;">⬅️ ${{pNode ? pNode.display_name : pId}}</span>
            ${{rationale ? `<span style="font-size: 10px; color: var(--text-muted); margin-top: 2px;">${{rationale}}</span>` : ""}}
          </div>
          <span style="color: var(--text-muted); font-size: 10px; flex-shrink: 0; margin-left: 8px;">${{pNode ? pNode.cost_points : 0}} 点</span>
        </div>
      `;
    }});
    if (!prereqHtml) prereqHtml = "<span style='color: var(--text-muted); font-size: 12px;'>无前置依赖（根节点）</span>";
    prereqsList.innerHTML = prereqHtml;

    // 后继科技列表
    const succList = document.getElementById("detail-successors-list");
    let succHtml = "";
    const succs = hardSuccessors.get(node.id) || [];
    succs.forEach(sId => {{
      const sNode = nodeMap.get(sId);
      const succRationale = (node.branch_successor_rationales || {{}})[sId] || "";
      succHtml += `
        <div class="relation-item" onclick="selectNode('${{sId}}', true)">
          <div style="display: flex; flex-direction: column;">
            <span style="font-weight: 600;">➡️ ${{sNode ? sNode.display_name : sId}}</span>
            ${{succRationale ? `<span style="font-size: 10px; color: var(--text-muted); margin-top: 2px;">${{succRationale}}</span>` : ""}}
          </div>
          <span style="color: var(--text-muted); font-size: 10px; flex-shrink: 0; margin-left: 8px;">${{sNode ? sNode.cost_points : 0}} 点</span>
        </div>
      `;
    }});
    if (!succHtml) succHtml = "<span style='color: var(--text-muted); font-size: 12px;'>无后续依赖（终节点）</span>";
    succList.innerHTML = succHtml;
  }}

  document.getElementById("btn-close-drawer").onclick = clearSelection;
  window.addEventListener("keydown", e => {{
    if (e.key === "Escape") clearSelection();
  }});

  viewport.addEventListener("dblclick", e => {{
    if (!e.target.closest(".tech-node-card")) clearSelection();
  }});

  // 搜索
  const searchInput = document.getElementById("tech-search");
  const searchDropdown = document.getElementById("search-results-dropdown");

  searchInput.addEventListener("input", e => {{
    const query = e.target.value.trim().toLowerCase();
    if (!query) {{
      searchDropdown.style.display = "none";
      return;
    }}

    const matches = RAW.nodes.filter(n => {{
      if (n.display_name.toLowerCase().includes(query)) return true;
      if (n.id.toLowerCase().includes(query)) return true;
      if (n.content_effects && n.content_effects.some(eff => (eff.display_name || "").toLowerCase().includes(query))) return true;
      return false;
    }}).slice(0, 10);

    if (matches.length === 0) {{
      searchDropdown.innerHTML = `<div style="padding: 12px; color: var(--text-muted); font-size: 12px;">未找到匹配科技</div>`;
      searchDropdown.style.display = "block";
      return;
    }}

    let dropHtml = "";
    matches.forEach(n => {{
      const era = eraMap.get(n.era_id);
      const domain = domainMap.get(n.domain_id);
      dropHtml += `
        <div class="search-res-item" onclick="selectNode('${{n.id}}', true); searchDropdown.style.display='none';">
          <div class="search-res-name">${{n.display_name}}</div>
          <div class="search-res-meta">${{domain ? domain.display_name : ""}} · ${{era ? era.display_name : ""}} · ${{n.id}}</div>
        </div>
      `;
    }});

    searchDropdown.innerHTML = dropHtml;
    searchDropdown.style.display = "block";
  }});

  document.addEventListener("click", e => {{
    if (!e.target.closest(".search-wrapper") && !e.target.closest("#search-results-dropdown")) {{
      searchDropdown.style.display = "none";
    }}
  }});

  // 领域过滤
  document.querySelectorAll(".filter-chip").forEach(chip => {{
    chip.onclick = () => {{
      chip.classList.toggle("active");
      applyFilters();
    }};
  }});

  // 边种类过滤
  document.querySelectorAll(".edge-chip").forEach(chip => {{
    chip.onclick = () => {{
      chip.classList.toggle("active");
      const kind = chip.dataset.kind;
      const isActive = chip.classList.contains("active");
      document.querySelectorAll(`.tech-edge.${{kind}}`).forEach(e => {{
        e.style.display = isActive ? "block" : "none";
      }});
    }};
  }});

  function applyFilters() {{
    const activeDomains = new Set();
    document.querySelectorAll(".filter-chip.active").forEach(c => activeDomains.add(c.dataset.domain));

    document.querySelectorAll(".tech-node-card").forEach(el => {{
      const dom = el.dataset.domain;
      el.style.display = activeDomains.has(dom) ? "flex" : "none";
    }});
  }}

  function init() {{
    calculateLayout();
    renderEraNav();
    renderLanesAndEras();
    renderNodeCards();
    renderEdges();
    updateTransform();
  }}

  init();
</script>
</body>
</html>
"""

    OUTPUT_HTML_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_HTML_PATH.write_text(html_content, encoding="utf-8")
    print(f"[SUCCESS] Wrote interactive application to {OUTPUT_HTML_PATH}")

    DOCS_HTML_PATH.parent.mkdir(parents=True, exist_ok=True)
    DOCS_HTML_PATH.write_text(html_content, encoding="utf-8")
    print(f"[SUCCESS] Wrote interactive application to {DOCS_HTML_PATH}")

if __name__ == "__main__":
    build_html()
