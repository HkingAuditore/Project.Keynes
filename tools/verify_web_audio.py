"""Verify actual Web Audio output after a trusted click, without autoplay bypass.

Requires Selenium; accepts --chrome / --chromedriver for local installations.
Captures output with an AnalyserNode before the destination (no duplicate mix).
"""
import argparse
import json
from pathlib import Path
import time

from selenium import webdriver
from selenium.webdriver import ActionChains
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service

PROBE = """
window.__audioProbe = [];
const originalConnect = AudioNode.prototype.connect;
AudioNode.prototype.connect = function(destination, ...args) {
    if (destination instanceof AudioDestinationNode) {
        const analyser = this.context.createAnalyser();
        analyser.fftSize = 2048;
        window.__audioProbe.push({context: this.context, analyser});
        originalConnect.call(analyser, destination);
        return originalConnect.call(this, analyser, ...args);
    }
    return originalConnect.call(this, destination, ...args);
};
"""
SAMPLE = """
return (window.__audioProbe || []).map(p => {
    const data = new Float32Array(p.analyser.fftSize);
    p.analyser.getFloatTimeDomainData(data);
    const rms = Math.sqrt(data.reduce((sum, v) => sum + v*v, 0) / data.length);
    return {state:p.context.state, rms, sampleRate:p.context.sampleRate};
});
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8060/ProjectKeynes.html")
    parser.add_argument("--chrome", default="")
    parser.add_argument("--chromedriver", default="")
    parser.add_argument("--out", default="tmp/web_audio_verify")
    args = parser.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    options = Options()
    if args.chrome:
        options.binary_location = args.chrome
    for flag in ["--headless=new", "--window-size=1600,960", "--no-sandbox",
                 "--ignore-gpu-blocklist", "--enable-unsafe-swiftshader"]:
        options.add_argument(flag)
    options.set_capability("goog:loggingPrefs", {"browser": "ALL"})
    driver = webdriver.Chrome(service=Service(args.chromedriver) if args.chromedriver else Service(),
                              options=options)
    try:
        driver.execute_cdp_cmd("Page.addScriptToEvaluateOnNewDocument", {"source": PROBE})
        driver.get(args.url)
        # Allow menu construction and the shader warmup overlay to finish.
        time.sleep(30)
        before = driver.execute_script(SAMPLE)
        canvas = driver.find_element("id", "canvas")
        ActionChains(driver).move_to_element(canvas).click().perform()
        samples = []
        for _ in range(30):
            time.sleep(0.2)
            samples.extend(driver.execute_script(SAMPLE))
        peak_rms = max((sample["rms"] for sample in samples), default=0.0)
        result = {"before_gesture": before, "after_gesture": samples,
                  "max_rms": peak_rms, "audible": peak_rms > 0.0001}
        (out / "audio.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
        (out / "console.json").write_text(json.dumps(driver.get_log("browser"), indent=2), encoding="utf-8")
        driver.save_screenshot(str(out / "menu.png"))
        print(json.dumps({"audible": result["audible"], "max_rms": peak_rms,
                          "before_gesture": before, "out": str(out)}, indent=2))
        return 0 if result["audible"] else 1
    finally:
        driver.quit()


if __name__ == "__main__":
    raise SystemExit(main())
