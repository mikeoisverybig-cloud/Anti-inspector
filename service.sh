#!/system/bin/sh

# Magisk 模块名: Anti-inspector
# 功能: 音量加键 + 电源键 → 松开电源键 → 3秒内再按一次电源键 = 冻结指定App

MODDIR=${0%/*}
APP_LIST="$MODDIR/apps.txt"
LOG_FILE="$MODDIR/freeze_action.log"
LOCK_DIR="$MODDIR/freeze.lock.d"

# Fix #6: FIFO 和 PID 文件移至 /data/local/tmp，避免模块目录早期启动只读问题
FIFO="/data/local/tmp/anti_inspector_$$.fifo"
PID_FILE="/data/local/tmp/anti_inspector_$$.pid"

# --- 1. 等待系统完全启动 ---
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
done

# --- 2. 日志函数 ---
log_msg() {
    if [ -f "$LOG_FILE" ]; then
        # Fix #3a: 用 stat 替代 wc -c，避免每次写日志都读取全部文件内容
        # Android 的 stat 在 busybox 下用 -c%s，在 toybox 下用 -f%z，两者都试
        local size
        size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)

        # Fix #3b: 超限时轮转（保留上一份备份）而非直接清空，防止丢失现场信息
        if [ "$size" -gt 102400 ]; then
            rm -f "${LOG_FILE}.bak"
            mv "$LOG_FILE" "${LOG_FILE}.bak" 2>/dev/null
        fi
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# --- 3. 震动反馈 ---
# Fix #5: 移除无效的 `input vibrator`，改用 sysfs 节点作为备选
vibrate() {
    local ms="$1"
    cmd vibrator vibrate "$ms" 2>/dev/null || \
    echo "$ms" > /sys/class/timed_output/vibrator/enable 2>/dev/null
}

# --- 4. 冻结逻辑（原子锁 + 日志序列化） ---
# Fix #2: freeze_apps 在后台运行时，其日志会与主循环日志交错。
# 用独立的 LOG_LOCK 目录序列化写日志：写前加锁、写后释放，保证每条日志完整输出。
# log_msg 本身是单条 echo，在 POSIX shell 里已是原子写入（管道缓冲 < 4096 字节），
# 因此只需对"连续多条日志"的批量输出块加锁即可。
LOG_LOCK_DIR="$MODDIR/log.lock.d"

log_block_begin() { while ! mkdir "$LOG_LOCK_DIR" 2>/dev/null; do sleep 0; done; }
log_block_end()   { rmdir "$LOG_LOCK_DIR" 2>/dev/null; }

# freeze_apps 后台实例的 PID（同时只允许一个，由 LOCK_DIR 保证）
FREEZE_PID=""

freeze_apps() {
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        log_msg "⚠️ 冻结任务正在执行中，跳过本次触发..."
        return
    fi

    log_block_begin
    log_msg "✅ 检测到按键连招，开始冻结应用..."

    if [ -f "$APP_LIST" ]; then
        while IFS= read -r pkg || [ -n "$pkg" ]; do
            # Fix #7: 去除 \r、BOM（\xEF\xBB\xBF）及首尾空白，防止编码问题导致包名匹配失败
            pkg=$(printf '%s' "$pkg" | tr -d '\r' | sed 's/^\xEF\xBB\xBF//;s/^[[:space:]]*//;s/[[:space:]]*$//')
            case "$pkg" in
                '' | '#'* ) continue ;;
            esac
            log_msg "正在冻结: $pkg"
            # Fix #6: 两条命令均失败时写入错误日志，而非静默忽略
            if ! pm disable-user --user 0 "$pkg" >/dev/null 2>&1 && \
               ! pm disable "$pkg" >/dev/null 2>&1; then
                log_msg "❌ 冻结失败（pm 命令均无效）: $pkg"
            fi
        done < "$APP_LIST"

        vibrate 300
        log_msg "❄️ 所有应用冻结完成"
    else
        log_msg "❌ 未找到应用列表文件: $APP_LIST"
    fi
    log_block_end

    rmdir "$LOCK_DIR" 2>/dev/null
}

# 非 combo_released 状态下 read 的心跳超时（秒）
# 用于周期性检测 getevent 是否仍存活（OTG、蓝牙设备切换等场景）
WATCHDOG_INTERVAL=10

# --- 5. 按键监听状态机 ---
monitor_keys() {
    local v_pressed=0
    local p_pressed=0
    local state="idle"
    local release_time=0
    local timeout_remaining line elapsed

    # ── 外层循环：getevent 退出/卡死后自动重启 ──────────────────────────────
    while true; do

        rm -f "$FIFO"
        mkfifo "$FIFO"

        # getevent 先启动（在 FIFO 写端阻塞，等读端 open 后同时解锁）
        getevent -lq > "$FIFO" &
        GETEVENT_PID=$!
        echo "$GETEVENT_PID" > "$PID_FILE"
        log_msg "📡 getevent 已启动 (PID: $GETEVENT_PID)"

        # 用固定文件描述符持续持有 FIFO 读端，避免每次 read 触发 open/close
        exec 3< "$FIFO"

        # getevent 重启后物理键状态未知，重置为"全部抬起"
        v_pressed=0
        p_pressed=0
        # 若 combo_released 窗口仍在有效期内则保留，否则复位
        if [ "$state" = "combo_released" ]; then
            elapsed=$(( $(date +%s) - release_time ))
            if [ "$elapsed" -ge 3 ]; then
                state="idle"
                log_msg "⏰ getevent 重启期间3秒窗口已过，已复位"
            else
                log_msg "🔄 getevent 已重启，combo_released 窗口尚未过期，继续等待"
            fi
        elif [ "$state" = "combo_held" ]; then
            # 组合键状态丢失，无法确认是否仍按着，安全复位
            state="idle"
            log_msg "↩️ getevent 重启，combo_held 状态已复位"
        fi

    # ── 内层循环：读取事件 ────────────────────────────────────────────────
    while true; do

        # ── 第一步：根据状态算出本轮 read 的超时时间 ────────────────────────
        # combo_released：用剩余窗口时间，保证3秒后必然复位
        # 其他状态    ：用 WATCHDOG_INTERVAL 做心跳，周期性探活 getevent
        if [ "$state" = "combo_released" ]; then
            timeout_remaining=$(( release_time + 3 - $(date +%s) ))

            if [ "$timeout_remaining" -le 0 ]; then
                state="idle"
                log_msg "⏰ 超时（计算），未触发冻结"
                continue
            fi

            # Fix A: 1秒地板——date +%s 是秒级整数；从计算到 read 调用有微小时差，
            # 若剩余恰好趋近 0，部分 shell 将 read -t 0 解释为"立即返回"而非等待，
            # 导致提前误判超时。强制最小值 1 可规避该边界情况。
            [ "$timeout_remaining" -lt 1 ] && timeout_remaining=1
        else
            # Fix B: idle/combo_held 也加超时，每 WATCHDOG_INTERVAL 秒探活一次 getevent
            timeout_remaining=$WATCHDOG_INTERVAL
        fi

        # ── 第二步：统一 read（只读一次）───────────────────────────────────
        if ! read -r -t "$timeout_remaining" line <&3; then
            # read 返回非零原因：
            #   ① combo_released 窗口超时
            #   ② watchdog 心跳超时（idle/combo_held）
            #   ③ FIFO EOF（getevent 已退出，写端关闭）

            if [ "$state" = "combo_released" ]; then
                state="idle"
                log_msg "⏰ 超时（read），未触发冻结"
            fi

            # Fix B 核心：探测 getevent 是否还活着
            # kill -0 成功 → 进程存在，属正常心跳超时 → continue 继续等待
            # kill -0 失败 → 进程已消失（OTG、设备重载等）→ break 触发外层重启
            if ! kill -0 "$GETEVENT_PID" 2>/dev/null; then
                log_msg "⚠️ getevent (PID $GETEVENT_PID) 已消失，准备重启..."
                break
            fi

            continue
        fi

        # 只关心按键事件，其余行跳过
        case "$line" in
            *KEY_VOLUMEUP*DOWN*)   v_pressed=1 ;;
            *KEY_VOLUMEUP*UP*)     v_pressed=0 ;;
            *KEY_POWER*DOWN*)      p_pressed=1 ;;
            *KEY_POWER*UP*)        p_pressed=0 ;;
            *) continue ;;
        esac

        # ==================== 状态机 ====================

        # 阶段 1: 两键同时按下 → combo_held
        if [ "$v_pressed" -eq 1 ] && [ "$p_pressed" -eq 1 ]; then
            if [ "$state" != "combo_held" ]; then
                state="combo_held"
                log_msg "🔒 组合键已按下 (Volume+ + Power)"
            fi
            continue
        fi

        # Fix #2: 从 combo_held 松开任意键时分情况处理
        # 原代码只检查 p_pressed=0，导致先松音量键时状态机永久卡住
        if [ "$state" = "combo_held" ]; then
            if [ "$p_pressed" -eq 0 ] && [ "$v_pressed" -eq 1 ]; then
                # 正确路径：先松电源键（音量键仍按着）→ 进入等待阶段
                state="combo_released"
                release_time=$(date +%s)
                log_msg "⏳ 已松开电源键，等待3秒内再次按下电源键..."
            else
                # 错误路径：先松音量键，或两键同时松 → 本次操作无效，复位
                state="idle"
                log_msg "↩️ 组合键中断（未按正确顺序松开），已复位"
            fi
            continue
        fi

        # 阶段 3: combo_released 期间收到事件
        if [ "$state" = "combo_released" ]; then
            if [ "$p_pressed" -eq 1 ]; then
                log_msg "🎯 触发条件满足！执行冻结操作"
                freeze_apps &
                FREEZE_PID=$!
                state="idle"
            fi
            # 其他按键（如音量键）在此阶段忽略，不复位，继续等待超时
        fi

    done  # ── 内层循环结束 ──

        # 内层退出后清理本轮 getevent 资源
        exec 3<&-
        kill "$GETEVENT_PID" 2>/dev/null
        rm -f "$PID_FILE" "$FIFO"
        log_msg "🔄 getevent 将在 2 秒后重启..."
        sleep 2

    done  # ── 外层循环结束（monitor_keys 永不主动返回）──
}

# --- 6. 信号清理 ---
cleanup() {
    # Fix #7: 等待后台 freeze_apps 完成，防止以下竞态：
    #   cleanup 先 rmdir LOCK_DIR → freeze_apps 尚未写完日志 / 尚未释放锁
    #   → 下次触发误以为无锁，并发执行两份冻结操作
    # 超时上限 10 秒，避免 freeze_apps 卡死时 cleanup 永久阻塞
    if [ -n "$FREEZE_PID" ] && kill -0 "$FREEZE_PID" 2>/dev/null; then
        log_msg "⏳ 等待冻结任务完成（最多10秒）..."
        local waited=0
        while kill -0 "$FREEZE_PID" 2>/dev/null && [ "$waited" -lt 10 ]; do
            sleep 1
            waited=$(( waited + 1 ))
        done
        if kill -0 "$FREEZE_PID" 2>/dev/null; then
            log_msg "⚠️ 冻结任务超时，强制终止 (PID: $FREEZE_PID)"
            kill "$FREEZE_PID" 2>/dev/null
        fi
    fi

    local gpid
    gpid="$(cat "$PID_FILE" 2>/dev/null)"
    [ -n "$gpid" ] && kill "$gpid" 2>/dev/null
    # 显式关闭 fd 3，防止 monitor_keys 被信号中断时文件描述符泄漏
    exec 3<&- 2>/dev/null
    rm -f "$FIFO" "$PID_FILE"
    rmdir "$LOCK_DIR" "$LOG_LOCK_DIR" 2>/dev/null
    log_msg "🛑 Anti-inspector 服务已退出"
}
trap cleanup INT TERM EXIT

# --- 7. 主循环 ---
log_msg "🚀 Anti-inspector 服务已启动"

while true; do
    monitor_keys
    log_msg "⚠️ monitor_keys 异常退出，3 秒后重启..."
    sleep 3
done
