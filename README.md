# boot-scripts - Personal boot scripts

此仓库用于个人开机启动脚本集合。每个功能独立为一个 `.sh`，统一入口脚本用于批量执行，也可单独运行。

**Directory Structure**
- `bin/boot.sh` 统一入口，支持 `--list` / `--run` / `--all`
- `scripts/*.sh` 功能脚本（可单独执行）
- `systemd/boot-scripts.service` 示例 systemd 服务文件

**Naming Convention**
- 统一使用小写 + 中划线（kebab-case），例如 `fix-time.sh`
- 需要固定执行顺序时，用数字前缀控制：`00-xxx.sh`, `10-xxx.sh`

**Usage**
```bash
# List available scripts
./bin/boot.sh --list

# Run one script (pass args after --)
./bin/boot.sh --run fix-time -- --install-service

# Run all scripts (lexicographic order)
./bin/boot.sh --all
```

**Run A Single Script**
```bash
chmod +x ./scripts/*.sh
./scripts/sshman.sh
./scripts/fix-time.sh --install-service
```

**Systemd Autostart (example)**
```bash
sudo cp systemd/boot-scripts.service /etc/systemd/system/
sudo sed -i 's|/opt/sshman|/path/to/sshman|g' /etc/systemd/system/boot-scripts.service
sudo systemctl daemon-reload
sudo systemctl enable --now boot-scripts.service
```

**Direct Download (raw)**
```bash
curl -fsSL https://raw.githubusercontent.com/zhbrcn/boot-scripts/main/scripts/sshman.sh -o sshman.sh \
  && chmod +x sshman.sh \
  && sudo ./sshman.sh
```
```bash
curl -fsSL https://raw.githubusercontent.com/zhbrcn/boot-scripts/main/scripts/fix-time.sh | sudo bash
```
```bash
curl -fsSL https://raw.githubusercontent.com/zhbrcn/boot-scripts/main/scripts/fix-time.sh | sudo bash -s -- --install-service
```
```bash
curl -fsSL https://raw.githubusercontent.com/zhbrcn/boot-scripts/main/scripts/fix-time.sh -o /tmp/fix-time.sh \
  && sed -n '1,200p' /tmp/fix-time.sh \
  && sudo bash /tmp/fix-time.sh --install-service
```
