import Foundation
import Darwin

// MARK: - 子进程（返回码 + stdout；继承环境、覆盖 LC_ALL/PATH 等）
func runProcRC(_ argv: [String], _ timeout: TimeInterval = 6) -> (Int32, String) {
    guard let path = argv.first, !path.isEmpty else { return (-1, "") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = Array(argv.dropFirst())
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    var env = ProcessInfo.processInfo.environment
    env["LC_ALL"] = "C"
    env["PYTHONIOENCODING"] = "utf-8"
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
    p.environment = env
    do { try p.run() } catch { return (-1, "") }

    // 输出用非阻塞 readabilityHandler 累积。为什么不用 readDataToEndOfFile：
    // 1) 守护式/后台启动（shell 退出但孙进程仍握着写端）会让 EOF 永远不来 → 误报超时；
    // 2) 超时后那条仍阻塞的读线程和管道 FD 会泄漏。readabilityHandler 两者都不发生。
    let lock = NSLock()
    var data = Data()
    let fh = out.fileHandleForReading
    let eofSem = DispatchSemaphore(value: 0)
    fh.readabilityHandler = { h in
        let d = h.availableData
        lock.lock()
        if d.isEmpty {                 // EOF
            h.readabilityHandler = nil
            lock.unlock()
            eofSem.signal()
        } else {
            data.append(d)
            lock.unlock()
        }
    }

    // 超时基准 =「进程退出」，而非管道 EOF。
    let exitSem = DispatchSemaphore(value: 0)
    // 状态门：terminationHandler 触发即置位。兜底补刀前先查它，
    // 避免进程已退出、PID 被复用后还向这个数字发信号（误杀无关进程）
    let stateLock = NSLock()
    var exited = false
    p.terminationHandler = { _ in
        stateLock.lock(); exited = true; stateLock.unlock()
        exitSem.signal()
    }

    if exitSem.wait(timeout: .now() + timeout) == .timedOut {
        fh.readabilityHandler = nil
        p.terminate()                                                    // SIGTERM 直接子进程
        // 兜底补刀：2s 后仍未退出则再发一次信号。
        // 不用裸 kill(pid, SIGKILL)：isRunning 检查与 kill 之间有 TOCTOU——进程恰在
        // 检查后退出且 PID 被复用时会误杀无关进程。改为「terminationHandler 状态门 +
        // Process 自身 API」，保证信号只发给自己启动的进程。
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            stateLock.lock(); let done = exited; stateLock.unlock()
            guard !done else { return }                                  // 已退出：绝不再发信号
            p.interrupt()                                                // SIGINT 补刀（TERM 被忽略时的第二手段）
        }
        _ = exitSem.wait(timeout: .now() + 3)                            // 给回收一个窗口，不无限等
        stateLock.lock(); let done = exited; stateLock.unlock()
        // 已退出才同步回收（立即返回）；两路信号都被无视的顽固进程不再无限阻塞调用线程，
        // 运行中的 Process 由系统持有至其退出，terminationHandler 迟早触发
        if done { p.waitUntilExit() }
        lock.lock(); let s = String(data: data, encoding: .utf8) ?? ""; lock.unlock()
        return (124, s)
    }

    // 已退出：短暂等管道 EOF 让最后一截输出落袋；孙进程未关写端则 0.25s 后放弃（不阻塞）。
    _ = eofSem.wait(timeout: .now() + 0.25)
    p.waitUntilExit()
    fh.readabilityHandler = nil
    lock.lock()
    let status = p.terminationStatus
    let s = String(data: data, encoding: .utf8) ?? ""
    lock.unlock()
    return (status, s)
}
func runProc(_ argv: [String], _ timeout: TimeInterval = 6) -> String { runProcRC(argv, timeout).1 }

// 执行配置里的命令（shell 字符串 / argv 数组两种形态）
func runCmd(_ c: Cmd, _ timeout: TimeInterval) -> (Int32, String) {
    if let s = c.shell { return runProcRC(["/bin/sh", "-c", s], timeout) }
    return runProcRC(c.argv, timeout)
}

// 端口连通探测（BSD socket，短超时）——服务/大模型都监听端口，直接探最即时
func portOpen(_ port: Int, _ timeout: TimeInterval = 0.4) -> Bool {
    guard (1...65535).contains(port) else { return false }
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else { return false }
    defer { close(sock) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let flags = fcntl(sock, F_GETFL, 0)
    _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if r == 0 { return true }
    if errno == EINPROGRESS {
        var fds = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let pr = poll(&fds, 1, Int32(timeout * 1000))
        if pr > 0 && (fds.revents & Int16(POLLOUT)) != 0 {
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len)
            return err == 0
        }
    }
    return false
}

// 进程名探测（pgrep -f），返回匹配 PID 列表
func pgrepPIDs(_ pattern: String) -> [String] {
    let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !p.isEmpty else { return [] }
    let (rc, out) = runProcRC(["/usr/bin/pgrep", "-f", p], 4)
    guard rc == 0 else { return [] }
    return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
}

// PID 文件探测：读 PID + kill -0 判存活 + proc_pidpath 防 PID 复用误判
func pidFileState(_ path: String) -> (Bool, [String]) {
    let p = expandPath(path)
    guard !p.isEmpty, let content = try? String(contentsOfFile: p, encoding: .utf8) else { return (false, []) }
    let first = content.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
    guard let pid = Int32(first) else { return (false, []) }
    guard kill(pid, 0) == 0 || errno == EPERM else { return (false, []) }
    // PID 复用防线：kill -0 只证明「这个 PID 存在」，不证明「是你的服务」（zombie 也算存活）。
    // 再取一次进程可执行路径：取不到（进程已死 / 僵尸 / PID 回收窗口）即判未运行，
    // 避免服务崩溃后 PID 被复用导致 ● 常亮、stop 分支误处理别的进程。
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return (false, []) }
    return (true, [String(pid)])
}