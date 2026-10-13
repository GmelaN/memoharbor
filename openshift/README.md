# OKD 자동 배포 — MemoHarbor

대상: OKD `4.22.0-okd-scos.9`, 프로젝트 `memoharbor`, MariaDB.
GitOps 없이 GitHub Actions가 검증된 이미지 digest로 Deployment를 갱신합니다.

```text
main push → WAR 테스트 → WildFly 이미지 빌드 → 실제 컨테이너/MariaDB 테스트
          → GHCR 업로드 → 사설망 self-hosted runner → OKD rolling update
```

이미지는 `quay.io/wildfly/wildfly:41.0.1.Final-jdk21` 기반입니다. 앱은 Java 17 바이트코드로 빌드되어 JDK 21에서도 실행됩니다.
기존 WildFly 27 호환 테스트에 더해 CI가 실제 배포 이미지에서 임의 UID 및 MariaDB를 검사합니다.
컨테이너/클러스터 노드는 현재 `linux/amd64`를 기준으로 합니다.

## 1. 사설망 Linux runner 준비

GitHub 저장소 Settings → Actions → Runners → New self-hosted runner에서 Linux x64 runner를 등록합니다.
클러스터 API와 GitHub에 접근 가능한 VM에 서비스로 설치하고 `okd-memoharbor` 라벨을 추가하십시오.
이 runner는 `main` 배포 job만 실행합니다. PR 빌드/테스트는 GitHub-hosted runner에서 실행합니다.

runner 실행 계정에 `git`, `bash`, `oc`를 설치하십시오. `oc`는 OKD 콘솔의 Command Line Tools에서 클러스터에 맞는 Linux 버전을 받습니다.
배포 runner에는 Docker나 MariaDB 비밀번호가 필요하지 않습니다.
OKD 노드는 GHCR 이미지에 접근할 수 있어야 합니다. MariaDB 연결도 Pod 네트워크에서 허용되어야 합니다.

## 2. 프로젝트와 DB Secret 생성 (관리자 PC/VM에서 1회)

먼저 `oc login`으로 로그인하고 프로젝트를 선택하거나 생성합니다.

```sh
oc project memoharbor || oc new-project memoharbor
```

MariaDB에 `memoharbor` DB와 앱 계정을 준비합니다. 기존 README의 관리자 SQL을 참고하십시오.
관리자 컴퓨터의 Git 저장소 밖에 UTF-8 `.env` 파일을 만들고 실제 값을 입력합니다.

```dotenv
DB_URL=jdbc:mariadb://YOUR_DB_HOST:3306/memoharbor
DB_USER=memoharbor
DB_PASSWORD='YOUR_DB_PASSWORD'
```

아래 명령의 경로를 해당 파일 경로로 바꿉니다. `--from-file`을 사용하여 `.env` 전체를 Secret의 `.env` 키에 저장합니다.
`--from-env-file`은 앱이 필요한 파일 구조와 다르므로 사용하지 않습니다.

```sh
oc -n memoharbor create secret generic memoharbor-db \
  --from-file=.env=/secure/memoharbor/.env \
  --dry-run=client -o yaml | oc apply -f -
```

Pod에서 `/etc/memoharbor/.env`로 읽기 전용 마운트합니다.
JVM에는 `-Dmemoharbor.env=/etc/memoharbor/.env`를 전달합니다.
Secret이 없으면 Pod가 시작되지 않고, DB 연결이 실패하면 readiness를 통과하지 않습니다. SQLite로 자동 전환하지 않습니다.
DB 비밀번호는 GitHub Secrets, 이미지, Git에 넣지 않습니다.

## 3. GHCR 읽기 권한 설정

`main`에 push하면 기존 WAR 검증 후 `ghcr.io/gmelan/memoharbor:sha-<commit>`과 `:main`을 발행합니다.
GitHub Actions는 자동 제공되는 `GITHUB_TOKEN`으로 업로드합니다 (`packages: write`).
기존 GHCR 패키지가 별도로 생성되어 있다면 패키지 설정에서 이 저장소의 Actions 쓰기 권한을 확인하십시오.

GHCR 패키지는 기본적으로 비공개일 수 있으므로, 아래 예시는 `read:packages` 권한의 전용 GitHub PAT으로 pull Secret을 생성합니다.
토큰은 신뢰할 수 있는 관리자 터미널에서 입력합니다. 다음은 Bash 예시입니다.

```sh
read -r -p 'GitHub user: ' GHCR_USER
read -r -s -p 'GHCR read token: ' GHCR_TOKEN; printf '\n'
oc -n memoharbor create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io --docker-username="$GHCR_USER" \
  --docker-password="$GHCR_TOKEN" --dry-run=client -o yaml | oc apply -f -
unset GHCR_TOKEN
```

Pod 전용 ServiceAccount가 이 Secret을 사용합니다. 이미지가 공개여도 현재 YAML을 그대로 사용하려면 pull Secret을 생성하거나 YAML의 `imagePullSecrets` 항목을 제거하십시오.

## 4. 초기 배포와 배포 계정 생성

GHCR에 첫 `:main` 이미지가 발행된 뒤 실행합니다.

```sh
oc apply -f openshift/app.yaml
oc apply -f openshift/deployer-rbac.yaml
oc apply -f openshift/deployer-token.yaml
oc -n memoharbor rollout status deployment/memoharbor --timeout=600s
oc -n memoharbor get route memoharbor
```

Route가 생성한 호스트의 `https://<route-host>/memoharbor/`에서 접속합니다.
초기 replicas는 1이며, MariaDB 공유와 Route sticky cookie를 설정하므로 필요하면 늘릴 수 있습니다.
로그인 세션은 Pod 메모리에 있어 Pod 교체 시 재로그인이 필요합니다.
관리 포트 9990은 Service/Route에 노출하지 않습니다.
임의 UID, `runAsNonRoot`, `RuntimeDefault`, capability 제거로 restricted SCC에 맞추며 `anyuid` 권한은 필요하지 않습니다.
클러스터의 추가 admission 정책에 따른 실제 검증은 초기 배포에서 확인해야 합니다.

## 5. GitHub 배포 설정

저장소 Settings → Environments에서 `okd` 환경을 만들고 다음 **환경 Secrets**를 설정합니다.

| 이름 | 값 |
|---|---|
| `OPENSHIFT_SERVER` | `oc whoami --show-server` 결과 (사설 API URL) |
| `OPENSHIFT_TOKEN` | `github-deployer-token` Secret에서 생성된 배포 계정 토큰 |
| `OPENSHIFT_CA_CERT` | API 인증서의 CA PEM 전체. 공인/runner 신뢰 CA 사용 시 생략 가능 |

토큰과 CA는 관리자 터미널에서 조회하여 GitHub의 Secret 입력란에 직접 넣습니다. 결과를 Git에 저장하거나 채팅에 전달하지 마십시오.

```sh
oc -n memoharbor get secret github-deployer-token -o jsonpath='{.data.token}' | base64 -d
oc -n memoharbor get secret github-deployer-token -o jsonpath='{.data.ca\.crt}' | base64 -d
```

두 번째 CA가 실제 API 인증서 체인과 맞지 않으면 클러스터 관리자가 제공한 API CA를 사용합니다. TLS 검증을 끄지 않습니다.
여기서는 자동화용 ServiceAccount token Secret을 명시적으로 생성합니다. 장기 토큰이므로 주기적으로 교체하십시오.
`oc create token`으로 발급한 토큰을 대신 사용할 수도 있지만 만료 전에 갱신해야 합니다.
배포 계정은 `memoharbor` Deployment의 조회·갱신만 허용되며 DB Secret 조회나 프로젝트 관리자 권한은 없습니다.

설정 완료 후 Settings → Secrets and variables → Actions → **Variables**에 저장소 변수 `OPENSHIFT_DEPLOY_ENABLED=true`를 추가합니다.
설정 전에는 이미지 빌드/발행까지만 실행되고 배포 job은 건너뜁니다.
Actions에서 `Build and release WAR` → Run workflow → `main`을 선택하면 최초 자동 배포를 실행할 수 있습니다.
이후 `main` push마다 자동 배포됩니다. PR 및 릴리스 태그는 OKD에 배포하지 않습니다.

사설망 runner가 offline이면 배포 job이 대기합니다. API나 CA, 토큰, 권한 오류는 배포 job 로그에서 확인합니다.
환경에 승인 규칙을 설정하면 자동 배포 전에 승인을 기다리므로, 무인 자동 배포가 목적이라면 환경 설정을 이에 맞춥니다.

## 6. 운영 및 변경

```sh
oc -n memoharbor get pods
oc -n memoharbor logs deployment/memoharbor
oc -n memoharbor rollout history deployment/memoharbor
```

`/live`는 DB 접속을 수행하지 않는 startup/liveness 점검입니다. `/health`는 실제 MariaDB 쿼리를 실행하는 readiness 점검입니다.
DB 오류만으로 이미 시작한 Pod를 재시작하지 않도록 분리했습니다.
Route에서 HTTPS를 종료하고 WildFly는 router forwarding 헤더를 인식합니다. 외부 접근은 Route를 통해 제공하십시오.

DB Secret을 변경한 뒤에는 앱이 시작할 때 설정을 읽으므로 재시작합니다.

```sh
oc -n memoharbor rollout restart deployment/memoharbor
oc -n memoharbor rollout status deployment/memoharbor --timeout=600s
```

필요 시 이전 이미지로 되돌립니다. 이미지 롤백은 DB 데이터를 되돌리지 않습니다.

```sh
oc -n memoharbor rollout undo deployment/memoharbor
oc -n memoharbor rollout status deployment/memoharbor --timeout=600s
```

자동 배포 job은 이미지와 변경 이력만 갱신합니다. 리소스·Route·probe 등의 YAML을 수정했다면 관리자가 `oc apply -f openshift/app.yaml`로 반영하십시오.
이 파일의 bootstrap `:main`을 다시 적용하면 이미지도 해당 태그로 돌아갈 수 있으므로 현재 digest로 맞춘 뒤 적용하거나 곧바로 자동 배포를 실행하십시오.

## 참고 문서

- [WildFly 컨테이너 이미지](https://docs.wildfly.org/wildfly-container/)
- [GHCR 이미지 발행](https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images)
- [OKD image pull Secret](https://docs.okd.io/4.19/openshift_images/managing_images/using-image-pull-secrets.html)
- [Kubernetes probe](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
- [ServiceAccount token Secret](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#manually-create-a-long-lived-api-token-for-a-serviceaccount)

OKD 4.22의 실제 클러스터 연결 및 배포 확인은 초기 설정 후 수행합니다.
