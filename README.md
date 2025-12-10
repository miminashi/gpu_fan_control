# gpu_fan_control

- GPUファンの電源をメインボード（X10DRG-Q）からとっている
- GPUの温度でファンの速度を動的にコントロールするためには、`rocm-smi`で温度を取得して、`ipmitool`でファンの速度を設定する必要がある
- claudeにつくってもらった

## claudeとの会話ログ

- https://claude.ai/share/24fdbaed-10c1-4612-a8b6-0bfa2f659569
- https://claude.ai/share/0647158c-69ed-4ba9-ab1e-eb534f13703d
