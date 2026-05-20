---
name: full-dots-baker-pipeline
overview: 将 4 个 atlas baker（dyn/eco/smooth/ice）的整条 pipeline 一次性下沉到 C++ DOTS：prep + merge + dilate + CSR 打包 + atlas encode + ImageTexture 写入 + chunk_step/finalize/调度节流 全部由 C++ 承担；C++ 直接读 World SoA TypedArray，内部维护上一帧 snapshot 做 value-diff，从 dirty_indices=2400 中过滤出真正变化 cell；GD 端 4 个 baker 类降为薄壳，每帧只调一次 run_atlas_pipeline()。
---

