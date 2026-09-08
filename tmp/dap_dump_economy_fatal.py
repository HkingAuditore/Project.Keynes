import json
import re
import socket
import time

HOST, PORT = "127.0.0.1", 6006
OUT = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_money_conservation_fatal.json"


class Dap:
    def __init__(self):
        self.sock = socket.create_connection((HOST, PORT), timeout=5)
        self.sock.settimeout(5)
        self.buf = b""
        self.seq = 1

    def send(self, command, arguments=None):
        req = {"seq": self.seq, "type": "request", "command": command}
        self.seq += 1
        if arguments is not None:
            req["arguments"] = arguments
        body = json.dumps(req).encode("utf-8")
        self.sock.sendall(
            f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body
        )
        return req["seq"]

    def recv_msg(self, timeout=5.0):
        self.sock.settimeout(timeout)
        while True:
            while b"\r\n\r\n" not in self.buf:
                chunk = self.sock.recv(65536)
                if not chunk:
                    raise RuntimeError("closed")
                self.buf += chunk
            header, rest = self.buf.split(b"\r\n\r\n", 1)
            m = re.search(br"Content-Length:\s*(\d+)", header, re.I)
            length = int(m.group(1))
            while len(rest) < length:
                chunk = self.sock.recv(65536)
                if not chunk:
                    raise RuntimeError("closed mid")
                rest += chunk
            body, self.buf = rest[:length], rest[length:]
            return json.loads(body.decode("utf-8"))

    def wait_for(self, pred, timeout=10.0):
        end = time.time() + timeout
        extras = []
        while time.time() < end:
            msg = self.recv_msg(timeout=max(0.1, end - time.time()))
            if pred(msg):
                return msg, extras
            extras.append(msg)
        raise TimeoutError("wait_for")

    def drain(self, seconds=0.5):
        end = time.time() + seconds
        out = []
        while time.time() < end:
            try:
                out.append(self.recv_msg(timeout=max(0.05, end - time.time())))
            except Exception:
                break
        return out


def main():
    dap = Dap()
    dap.send(
        "initialize",
        {
            "clientID": "cursor-agent3",
            "adapterID": "godot",
            "pathFormat": "path",
            "linesStartAt1": True,
            "columnsStartAt1": True,
        },
    )
    dap.drain(1)
    dap.send("attach", {"request": "attach"})
    dap.drain(2)
    dap.send("configurationDone")
    dap.drain(1)

    dap.send("pause", {"threadId": 1})
    stopped, extras = dap.wait_for(
        lambda m: m.get("type") == "event" and m.get("event") == "stopped", timeout=5
    )
    print("stopped", stopped)
    print("extras", len(extras))

    dap.send("threads")
    threads, _ = dap.wait_for(
        lambda m: m.get("type") == "response" and m.get("command") == "threads",
        timeout=5,
    )
    print("threads", threads)
    thread_id = 1
    for t in (threads.get("body") or {}).get("threads") or []:
        thread_id = t.get("id", 1)
        break

    dap.send("stackTrace", {"threadId": thread_id, "startFrame": 0, "levels": 20})
    stack, _ = dap.wait_for(
        lambda m: m.get("type") == "response" and m.get("command") == "stackTrace",
        timeout=5,
    )
    print("stack", json.dumps(stack, ensure_ascii=False)[:1200])
    frames = ((stack.get("body") or {}).get("stackFrames") or [])
    frame_id = frames[0]["id"] if frames else 0
    print("frame_id", frame_id)

    # Dump via expression that writes a file using Godot APIs.
    # Keep expression short and avoid multiline.
    expr = (
        '(func(p):'
        ' var root=Engine.get_main_loop().root;'
        ' var report={};'
        ' var stack=[root];'
        ' while stack.size()>0:'
        '  var n=stack.pop_back();'
        '  if n.has_method("get_economy_report"):'
        '   report=n.get_economy_report(); break;'
        '  for c in n.get_children(): stack.push_back(c);'
        ' var keys=["fatal","fatal_reason","money_error","money_open","money_close","money_expected","explicit_money_mint","explicit_money_burn","opening_cohort_funds","closing_cohort_funds","opening_country_cash","closing_country_cash","opening_escrow_cash","closing_escrow_cash","opening_expedition_funds","closing_expedition_funds","producer_support_money_issued","bullion_money_issued","opening_audit_fast_paths","opening_audit_full_verifications","closing_audit_mode","sample_day","epoch_id","current_day","last_completed_sample_day"];'
        ' var out={};'
        ' for k in keys: if report.has(k): out[k]=report[k];'
        ' var f=FileAccess.open(p,FileAccess.WRITE);'
        ' if f!=null: f.store_string(JSON.stringify(out)); f.close();'
        ' return str(out.get("money_error","no"))+"|"+str(out.size());'
        ').call("%s")' % OUT.replace("\\", "/")
    )
    dap.send(
        "evaluate",
        {"expression": expr, "frameId": frame_id, "context": "repl"},
    )
    try:
        resp, more = dap.wait_for(
            lambda m: m.get("type") == "response" and m.get("command") == "evaluate",
            timeout=15,
        )
        print("EVAL", json.dumps(resp, ensure_ascii=False)[:2000])
        for m in more[-5:]:
            print("more", json.dumps(m, ensure_ascii=False)[:300])
    except Exception as e:
        print("eval err", e)
        for m in dap.drain(2):
            print("drain", json.dumps(m, ensure_ascii=False)[:300])

    dap.send("continue", {"threadId": thread_id})
    dap.drain(1)
    dap.sock.close()


if __name__ == "__main__":
    main()
