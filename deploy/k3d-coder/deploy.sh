#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
deploy_dir="${repo_root}/deploy/k3d-coder"
namespace="coder"
cluster_name="openchoreo"
lan_ip="${CODER_LAN_IP:-$(ipconfig getifaddr en0)}"
image_tag="local-$(git -C "${repo_root}" rev-parse --short HEAD)"
short_sha="$(git -C "${repo_root}" rev-parse --short HEAD)"
image="coder:${image_tag}"
coder_version=""
build_dir="${repo_root}/build"
binary="${repo_root}/build/coder-linux-amd64"
tools_dir="${build_dir}/tools"
helm_version="$(sed -nE 's/^helm = "([^"]+)"/\1/p' "${repo_root}/mise.toml")"
temp_values="$(mktemp)"
image_context="$(mktemp -d)"

cleanup() {
	rm -f "${temp_values}"
	rm -rf "${image_context}"
}
trap cleanup EXIT

if ! [[ "${lan_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
	echo "CODER_LAN_IP must be an IPv4 address; got '${lan_ip}'." >&2
	exit 1
fi

if [[ "$(kubectl config current-context)" != "k3d-${cluster_name}" ]]; then
	echo "Expected Kubernetes context k3d-${cluster_name}; refusing to deploy to another cluster." >&2
	exit 1
fi

helm_bin="$(command -v helm || true)"
if [[ -z "${helm_bin}" ]] || [[ "$(${helm_bin} version --short 2>/dev/null | cut -d. -f1)" != "v3" ]]; then
	case "$(uname -m)" in
		x86_64) helm_arch=amd64 ;;
		arm64|aarch64) helm_arch=arm64 ;;
		*) echo "Unsupported macOS architecture: $(uname -m)" >&2; exit 1 ;;
	esac
	helm_dir="${tools_dir}/helm-v${helm_version}"
	if [[ ! -x "${helm_dir}/darwin-${helm_arch}/helm" ]]; then
		mkdir -p "${helm_dir}"
		curl --fail --location --retry 2 \
			--output "${helm_dir}/helm.tar.gz" \
			"https://get.helm.sh/helm-v${helm_version}-darwin-${helm_arch}.tar.gz"
		tar -xzf "${helm_dir}/helm.tar.gz" -C "${helm_dir}"
		rm -f "${helm_dir}/helm.tar.gz"
	fi
	helm_bin="${helm_dir}/darwin-${helm_arch}/helm"
fi

go_version="$(sed -nE 's/^go = "([^\"]+)"/\1/p' "${repo_root}/mise.toml")"
go_bin="$(command -v go || true)"
if [[ -z "${go_bin}" ]] || [[ "$(${go_bin} version 2>/dev/null)" != *"go${go_version}"* ]]; then
	case "$(uname -m)" in
		x86_64) go_arch=amd64 ;;
		arm64|aarch64) go_arch=arm64 ;;
		*) echo "Unsupported macOS architecture: $(uname -m)" >&2; exit 1 ;;
	esac
	go_dir="${tools_dir}/go${go_version}.darwin-${go_arch}"
	go_bin="${go_dir}/go/bin/go"
	if [[ ! -x "${go_bin}" ]]; then
		mkdir -p "${go_dir}"
		curl --fail --location --retry 2 \
			"https://go.dev/dl/go${go_version}.darwin-${go_arch}.tar.gz" \
			| tar -xzf - -C "${go_dir}"
	fi
fi
if [[ ! -x "${go_bin}" ]]; then
	echo "Unable to locate Go ${go_version}." >&2
	exit 1
fi

if ! command -v pnpm >/dev/null 2>&1 || ! command -v npx >/dev/null 2>&1; then
	echo "Node.js, pnpm, and npx are required to build the web interface." >&2
	exit 1
fi

node_version="$(sed -nE 's/^node = "([^\"]+)"/\1/p' "${repo_root}/mise.toml")"
node_bin="$(command -v node)"
current_node_major="$("${node_bin}" --version | sed -E 's/^v([0-9]+).*/\1/')"
if ((current_node_major < 22 || current_node_major >= 25)); then
	case "$(uname -m)" in
		x86_64) node_arch=x64 ;;
		arm64|aarch64) node_arch=arm64 ;;
		*) echo "Unsupported macOS architecture: $(uname -m)" >&2; exit 1 ;;
	esac
	node_dir="${tools_dir}/node-v${node_version}-darwin-${node_arch}"
	node_bin="${node_dir}/bin/node"
	if [[ ! -x "${node_bin}" ]]; then
		mkdir -p "${tools_dir}"
		curl --fail --location --retry 2 \
			"https://nodejs.org/dist/v${node_version}/node-v${node_version}-darwin-${node_arch}.tar.xz" \
			| tar -xJf - -C "${tools_dir}"
	fi
fi
export PATH="$(dirname "${node_bin}"):$(dirname "$(command -v npx)"):${PATH}"

if git -C "${repo_root}" tag | grep -q .; then
	last_tag="$(git -C "${repo_root}" tag --contains "$(git -C "${repo_root}" rev-parse HEAD)" --sort=version:refname | head -n 1)"
	if [[ -z "${last_tag}" ]]; then
		last_tag="$(git -C "${repo_root}" tag --sort=version:refname | tail -n 1)"
	fi
else
	last_tag=v2.0.0
fi
coder_version="${last_tag#v}-devel+${short_sha}"
mkdir -p "${build_dir}"
echo "Building the production web interface..."
(
	cd "${repo_root}/site"
	npx --yes pnpm@10.33.2 install --frozen-lockfile
	npx --yes pnpm@10.33.2 run build
)
echo "Building Coder ${coder_version} from the current source..."
(
	cd "${repo_root}"
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 "${go_bin}" build \
		-tags "embed,ts_omit_aws,ts_omit_bird,ts_omit_tap,ts_omit_kube" \
		-ldflags "-X github.com/coder/coder/v2/buildinfo.tag=${coder_version} -s -w" \
		-o "${binary}" \
		./enterprise/cmd/coder
)

base_image="${CODER_BASE_IMAGE_TAG:-ghcr.io/coder/coder-base:latest}"
docker pull --platform linux/amd64 "${base_image}"
cp "${binary}" "${image_context}/coder"
cp "${repo_root}/scripts/Dockerfile" "${image_context}/Dockerfile"
docker build --platform linux/amd64 \
	--build-arg "BASE_IMAGE=${base_image}" \
	--build-arg "CODER_VERSION=${coder_version}" \
	--tag "${image}" \
	-f "${image_context}/Dockerfile" \
	"${image_context}"

host="coder.${lan_ip}.nip.io"
wildcard_host="*.coder.${lan_ip}.nip.io"
access_url="http://${host}:18080"
wildcard_access_url="${wildcard_host}"

sed \
	-e "s|http://coder\.192\.168\.1\.3\.nip\.io:18080|${access_url}|" \
	-e "s|http://\*\.coder\.192\.168\.1\.3\.nip\.io:18080|${wildcard_access_url}|" \
	-e "s|coder\.192\.168\.1\.3\.nip\.io|${host}|g" \
	-e "s|\*\.coder\.192\.168\.1\.3\.nip\.io|${wildcard_host}|g" \
	"${deploy_dir}/values.yaml" >"${temp_values}"

echo "Importing ${image} into k3d cluster ${cluster_name}..."
k3d image import "${image}" --cluster "${cluster_name}" --mode direct

echo "Creating Coder namespaces and workspace limits..."
kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${deploy_dir}/namespace.yaml"

if ! kubectl get secret coder-db-url -n "${namespace}" >/dev/null 2>&1; then
	password="$(openssl rand -hex 32)"
	kubectl create secret generic coder-db-url \
		-n "${namespace}" \
		--from-literal="password=${password}" \
		--from-literal="url=postgres://coder:${password}@coder-postgres.${namespace}.svc.cluster.local:5432/coder?sslmode=disable"
fi

echo "Creating persistent PostgreSQL and backup storage..."
kubectl apply -f "${deploy_dir}/postgres.yaml"
kubectl apply -f "${deploy_dir}/backup.yaml"
kubectl rollout status statefulset/coder-postgres -n "${namespace}" --timeout=10m

echo "Building the local Helm chart dependencies..."
"${helm_bin}" dependency build "${repo_root}/helm/coder"
"${helm_bin}" lint "${repo_root}/helm/coder" -f "${temp_values}"

echo "Installing Coder ${coder_version} at ${access_url}..."
"${helm_bin}" upgrade --install coder "${repo_root}/helm/coder" \
	--namespace "${namespace}" \
	-f "${temp_values}" \
	--set-string "coder.image.tag=${image_tag}" \
	--wait \
	--timeout 10m

echo "Waiting for the Coder route to be accepted..."
route_accepted=false
for _ in {1..30}; do
	if kubectl get httproute coder -n "${namespace}" -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null | grep -q True; then
		route_accepted=true
		break
	fi
	sleep 2
done
if [[ "${route_accepted}" != true ]]; then
	kubectl describe httproute coder -n "${namespace}"
	echo "The Gateway did not accept the Coder route." >&2
	exit 1
fi

echo "Checking the Coder health endpoint through the LAN Gateway..."
curl --fail --silent --show-error --retry 15 --retry-delay 2 --retry-connrefused --max-time 5 "${access_url}/healthz" >/dev/null

kubectl get deployment,statefulset,pvc,cronjob -n "${namespace}"
kubectl get httproute coder -n "${namespace}" -o wide
echo
echo "Coder is available on this LAN at ${access_url}"
echo "The first user created through the web setup flow becomes the deployment owner."
