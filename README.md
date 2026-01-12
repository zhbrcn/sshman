# sshman - For personal use only

```
curl -fsSL https://raw.githubusercontent.com/zhbrcn/sshman/main/sshman.sh -o sshman.sh && chmod +x sshman.sh && ./sshman.sh
```

```
curl -fsSL https://raw.githubusercontent.com/zhbrcn/sshman/refs/heads/main/fix-time.sh | sudo bash
```
```
curl -fsSL https://raw.githubusercontent.com/zhbrcn/sshman/refs/heads/main/fix-time.sh | sudo bash -s -- --install-service
```
```
curl -fsSL https://raw.githubusercontent.com/zhbrcn/sshman/refs/heads/main/fix-time.sh -o /tmp/fix-time.sh \
  && sed -n '1,200p' /tmp/fix-time.sh \
  && sudo bash /tmp/fix-time.sh --install-service
```
