# Ubuntu VM test environment (qemu/KVM on beelink)

Reference environment for GUI testing where WebKitGTK works.

- Dir: ~/vm-test (noble-server-cloudimg-amd64.img + overlay.qcow2 + seed.img)
- Boot: qemu-system-x86_64 -enable-kvm -m 4096 -smp 4 \
    -drive file=overlay.qcow2,if=virtio -drive file=seed.img,if=virtio,format=raw \
    -netdev user,id=n1,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=n1 \
    -display none -daemonize -pidfile vm.pid
- SSH: ssh -i ~/.ssh/oc-vm-key -p 2222 ubuntu@localhost (passwordless sudo inside)
- GUI test: Xvfb :99 + `DISPLAY=:99 LIBGL_ALWAYS_SOFTWARE=1 <app>` + `import -window root shot.png`
