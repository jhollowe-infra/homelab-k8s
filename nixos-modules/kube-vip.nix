{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelabK3s;
  vipAddress = "10.10.100.10";
  vipHostname = "k8s-api-vip.kube-nodes.johnhollowell.internal";
  manifest = pkgs.writeText "kube-vip.yaml" ''
    apiVersion: v1
    kind: Pod
    metadata:
      name: kube-vip
      namespace: kube-system
    spec:
      containers:
        - name: kube-vip
          image: ghcr.io/kube-vip/kube-vip:v1.2.4
          imagePullPolicy: IfNotPresent
          args:
            - manager
          env:
            - name: vip_arp
              value: "true"
            - name: vip_interface
              value: "__VIP_INTERFACE__"
            - name: vip_subnet
              value: "32"
            - name: cp_enable
              value: "true"
            - name: cp_namespace
              value: kube-system
            - name: vip_leaderelection
              value: "true"
            - name: vip_leaseduration
              value: "5"
            - name: vip_renewdeadline
              value: "3"
            - name: vip_retryperiod
              value: "1"
            - name: address
              value: "${vipAddress}"
            - name: port
              value: "6443"
            - name: k8s_config_file
              value: /etc/kubernetes/admin.conf
          securityContext:
            capabilities:
              add:
                - NET_ADMIN
                - NET_RAW
          volumeMounts:
            - name: kubeconfig
              mountPath: /etc/kubernetes/admin.conf
              readOnly: true
      hostNetwork: true
      volumes:
        - name: kubeconfig
          hostPath:
            path: /etc/rancher/k3s/k3s.yaml
            type: File
  '';
in
{
  config = lib.mkIf cfg.enable {
    homelabK3s.tlsSan = [
      vipHostname
      vipAddress
    ];

    environment.etc."kube-vip/kube-vip.yaml".source = manifest;

    systemd.services.kube-vip-manifest = {
      description = "Generate kube-vip static pod manifest";
      before = [ "k3s.service" ];
      requiredBy = [ "k3s.service" ];
      after = [ "systemd-networkd.service" ];
      path = with pkgs; [
        coreutils
        gawk
        iproute2
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        manifest_dir=/var/lib/rancher/k3s/agent/pod-manifests
        install -d -m 0755 "$manifest_dir"

        interface=""
        for attempt in {1..30}; do
          interface="$(ip -o route get ${config.homelabNetwork.gateway} 2>/dev/null \
            | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }' || true)"
          if [[ -n "$interface" ]]; then
            break
          fi
          sleep 1
        done
        if [[ -z "$interface" ]]; then
          echo "Could not determine the LAN interface for kube-vip" >&2
          exit 1
        fi

        manifest_tmp="$(mktemp "$manifest_dir/kube-vip.yaml.XXXXXX")"
        trap 'rm -f "$manifest_tmp"' EXIT
        sed "s/__VIP_INTERFACE__/$interface/" /etc/kube-vip/kube-vip.yaml > "$manifest_tmp"
        chmod 0644 "$manifest_tmp"
        mv "$manifest_tmp" "$manifest_dir/kube-vip.yaml"
      '';
    };
  };
}
