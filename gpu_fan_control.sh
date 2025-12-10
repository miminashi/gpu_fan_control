#!/bin/sh

# 設定
CHECK_INTERVAL=2
CURRENT_SPEED=0

# ファン速度制御の設定（一次関数のパラメータ）
MIN_TEMP=30      # 最低温度（これ以下は最低速度）
MAX_TEMP=80      # 最高温度（これ以上は最高速度）
MIN_SPEED=20     # 最低ファン速度（%）
MAX_SPEED=100    # 最高ファン速度（%）
HYSTERESIS=1     # ヒステリシス（°C）- ファン速度変更の閾値

# 色の定義（オプション）
if [ -t 1 ]; then
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    YELLOW=''
    GREEN=''
    BLUE=''
    NC=''
fi

# ファン速度を設定する関数
set_fan_speed() {
    speed_percent=$1
    speed_hex=$(printf '0x%02x' "$speed_percent")
    ipmitool raw 0x30 0x70 0x66 0x01 0x01 "$speed_hex" > /dev/null 2>&1

    CURRENT_SPEED=$speed_percent
}

# GPU温度を取得する関数（全GPUの最大温度）
get_max_gpu_temp() {
    temp=$(rocm-smi 2>/dev/null | grep -E '^\s*[0-9]+\s+[0-9]+' | \
           awk '{print $5}' | sed 's/°C//g' | sort -n | tail -1)

    if [ -z "$temp" ]; then
        echo "0"
    else
        # 小数点を削除して整数に（シェルスクリプトの比較用）
        echo "$temp" | awk '{printf "%d", $1}'
    fi
}

# 温度からファン速度を計算する関数（一次関数）
calculate_fan_speed() {
    temp=$1
    
    # 温度が最低温度以下の場合
    if [ "$temp" -le "$MIN_TEMP" ]; then
        echo "$MIN_SPEED"
        return
    fi
    
    # 温度が最高温度以上の場合
    if [ "$temp" -ge "$MAX_TEMP" ]; then
        echo "$MAX_SPEED"
        return
    fi
    
    # 一次関数で計算: speed = MIN_SPEED + (MAX_SPEED - MIN_SPEED) * (temp - MIN_TEMP) / (MAX_TEMP - MIN_TEMP)
    speed=$(awk -v temp="$temp" \
                -v min_temp="$MIN_TEMP" \
                -v max_temp="$MAX_TEMP" \
                -v min_speed="$MIN_SPEED" \
                -v max_speed="$MAX_SPEED" \
                'BEGIN {
                    ratio = (temp - min_temp) / (max_temp - min_temp)
                    speed = min_speed + (max_speed - min_speed) * ratio
                    printf "%d", speed
                }')
    
    echo "$speed"
}

# 温度に応じた状態を判定する関数
get_temp_status() {
    temp=$1
    
    if [ "$temp" -gt 75 ]; then
        echo "${RED}危険"
    elif [ "$temp" -gt 65 ]; then
        echo "${RED}高温"
    elif [ "$temp" -gt 55 ]; then
        echo "${YELLOW}やや高温"
    elif [ "$temp" -gt 45 ]; then
        echo "${YELLOW}注意"
    elif [ "$temp" -gt 35 ]; then
        echo "${GREEN}やや注意"
    else
        echo "${GREEN}正常"
    fi
}

# シグナルハンドラ（終了時に自動制御に戻す）
cleanup() {
    echo ""
    echo "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] 終了します...${NC}"
    echo "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] ファン制御を自動モードに戻しています${NC}"
    ipmitool raw 0x30 0x45 0x01 0x00 > /dev/null 2>&1
    exit 0
}

trap cleanup INT TERM

# メイン処理開始
echo "${BLUE}========================================${NC}"
echo "${BLUE}  GPU温度監視型ファン制御スクリプト${NC}"
echo "${BLUE}  (一次関数制御モード)${NC}"
echo "${BLUE}========================================${NC}"
echo ""
echo "${BLUE}設定:${NC}"
echo "  温度範囲: ${MIN_TEMP}°C - ${MAX_TEMP}°C"
echo "  ファン速度範囲: ${MIN_SPEED}% - ${MAX_SPEED}%"
echo "  ヒステリシス: ${HYSTERESIS}°C"
echo ""

# rootで実行しているかチェック
if [ "$(id -u)" -ne 0 ]; then
    echo "${RED}エラー: このスクリプトはroot権限で実行してください${NC}"
    exit 1
fi

# rocm-smiが利用可能かチェック
if ! command -v rocm-smi > /dev/null 2>&1; then
    echo "${RED}エラー: rocm-smiコマンドが見つかりません${NC}"
    exit 1
fi

# ipmitoolが利用可能かチェック
if ! command -v ipmitool > /dev/null 2>&1; then
    echo "${RED}エラー: ipmitoolコマンドが見つかりません${NC}"
    exit 1
fi

## 初期設定: MIN_SPEED%
#echo "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] 初期化: ファン速度を${MIN_SPEED}%に設定${NC}"
#set_fan_speed "$MIN_SPEED"
# 初期設定: MAX_SPEED%
echo "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] 初期化: ファン速度を${MAX_SPEED}%に設定${NC}"
set_fan_speed "$MAX_SPEED"
sleep 3

echo "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] 監視を開始します (Ctrl+C で終了)${NC}"
echo ""

# 前回の温度を保存（ヒステリシス用）
PREV_TEMP=0

# メインループ
while true; do
    # GPU温度を取得
    max_temp=$(get_max_gpu_temp)

    # 温度取得失敗時
    if [ "$max_temp" -eq 0 ]; then
        echo "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] 警告: GPU温度を取得できませんでした${NC}"
        sleep "$CHECK_INTERVAL"
        continue
    fi
   
    # 必要なファン速度を一次関数で計算
    target_speed=$(calculate_fan_speed "$max_temp")
    
    # 状態を取得
    status=$(get_temp_status "$max_temp")
    
    # ファン速度が変更される場合のみ設定
    if [ "$target_speed" -ne "$CURRENT_SPEED" ]; then
        echo "${status} [$(date '+%Y-%m-%d %H:%M:%S')] GPU温度: ${max_temp}°C -> ファン速度を ${CURRENT_SPEED}% から ${target_speed}% に変更${NC}"
        PREV_TEMP=$max_temp
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] GPU温度: ${max_temp}°C - ファン速度: ${CURRENT_SPEED}%"
    fi
    set_fan_speed "$target_speed"

    # 指定秒数待機
    sleep "$CHECK_INTERVAL"
done
