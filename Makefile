.PHONY: install uninstall check deploy

PREFIX ?= /usr/local
BIN = $(PREFIX)/bin
SCRIPT = spindown-guard.sh

install:
	install -Dm755 $(SCRIPT) $(BIN)/spindown-guard
	@echo "✔ 已安装到 $(BIN)/spindown-guard"
	@echo ""
	@echo "  下一步:"
	@echo "    spindown-guard --select -t 20     # 交互式选择硬盘"
	@echo "    spindown-guard --install           # 安装 systemd 开机启动"
	@echo "    spindown-guard --status            # 查看状态"

uninstall:
	-spindown-guard --uninstall 2>/dev/null || true
	-rm -f $(BIN)/spindown-guard

check:
	bash -n $(SCRIPT) && echo "✔ 语法 OK"
	@shellcheck $(SCRIPT) 2>/dev/null || true

deploy:
	scp $(SCRIPT) pve:/tmp/spindown-guard.sh
	ssh pve 'install -Dm755 /tmp/spindown-guard.sh /usr/local/bin/spindown-guard && rm /tmp/spindown-guard.sh && echo "✔ 已部署到 PVE"'
