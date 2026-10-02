# Discrete NVIDIA GPU passthrough support. Import this only on the node(s)
# that actually have an NVIDIA card passed through via Terraform hostpci
# (see hosts/hl01-kube03/default.nix for the commented-out example).
#
# Pinned for a Quadro P620 (Pascal / GP107):
#   - `open = false` is not optional here - Pascal has no GSP (GPU System
#     Processor) so it CANNOT use NVIDIA's open-source kernel module at
#     all (that requires Turing+). Proprietary driver only. Verified against
#     nixpkgs source (nixos/modules/hardware/video/nvidia.nix): for driver
#     >= 560, `open` defaults to `null` and nixpkgs asserts it must be set
#     explicitly - `false` is the correct explicit value here regardless of
#     which driver branch/version ends up selected, since open modules
#     require Turing+ either way.
#   - The P620 needs the `legacy_580` branch, not `stable`: NVIDIA's own
#     driver download page for the Quadro P620 lists 580.178.04 (released
#     2026-08-03) as the latest available Linux driver for this card - no
#     590+ driver exists for it. nixpkgs' `legacy_580` branch is exactly
#     that version (pkgs/os-specific/linux/nvidia-x11/default.nix), while
#     `stable` is currently 595.104.02, which does not support this card.
#     nixpkgs describes `legacy_580` as "the long-lived 580 series (LTSB),
#     for GPUs that newer driver branches no longer support (often Maxwell
#     through Volta; roughly GeForce GTX 9xx through 10xx, plus rare Volta
#     cards like TITAN V)".
#   - NVENC on the P620 is capped at 3 concurrent encode streams by default
#     (community `nvidia-patch` can lift this - not applied here).
#
# hardware.nvidia-container-toolkit.{enable,mount-nvidia-executables} and
# services.k3s.containerdConfigTemplate verified against nixpkgs source:
# nixos/modules/services/hardware/nvidia-container-toolkit/default.nix
# defines both options as used below (enable: bool, default false;
# mount-nvidia-executables: bool, default true, mounts nvidia-smi et al.
# into containers), and pkgs/by-name/nv/nvidia-container-toolkit/package.nix
# confirms the `tools` output contains `nvidia-container-runtime.cdi`, the
# binary referenced in the containerd runtime options below. The
# containerdConfigTemplate option itself is defined in
# nixos/modules/services/cluster/rancher/default.nix (see nixos-modules/k3s.nix).
{
  config,
  lib,
  pkgs,
  ...
}:
{
  hardware.graphics.enable = true;

  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    modesetting.enable = true;
    powerManagement.enable = false;
    open = false; # required: Pascal has no GSP, open module will not load
    package = config.boot.kernelPackages.nvidiaPackages.legacy_580; # stable (595+) does not support the P620
  };

  hardware.nvidia-container-toolkit = {
    enable = true;
    mount-nvidia-executables = true;
  };

  # Wire the NVIDIA runtime into k3s's embedded containerd so pods can
  # request it via RuntimeClass. The cluster-side RuntimeClass object and
  # the nvidia-device-plugin DaemonSet (which advertises nvidia.com/gpu)
  # are installed once, cluster-wide, from the app-deployment repo - not
  # here, since they're not per-node config.

  services.k3s.containerdConfigTemplate = ''
    {{ template "base" . }}

    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
      privileged_without_host_devices = false
      runtime_engine = ""
      runtime_root = ""
      runtime_type = "io.containerd.runc.v2"

      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
        BinaryName = "${pkgs.nvidia-container-toolkit.tools}/bin/nvidia-container-runtime.cdi"
  '';

  environment.systemPackages = with pkgs; [
    # make debugging easier
    pciutils
  ];

  homelabK3s.nodeLabels."homelab/gpu-nvidia" = "true";
  # this is what the NVIDIA device-plugin requires
  homelabK3s.nodeLabels."nvidia.com/gpu.present" = "true";
}
