# MemoHarbor

프로젝트 **A** — 독립형 메모장. APM 시스템/WAS 에이전트 설치 및 관측을 위한 작은 독립형 웹앱입니다.
다른 웹앱을 호출하지 않습니다. 등록·조회·삭제 요청이 실제 SQLite JDBC 쿼리를 실행합니다.

## 환경 및 빌드

- 실행 기준: **WildFly 27 이상 / Java 17 이상** (Jakarta EE 10, `jakarta.servlet` 6.0). Tomcat 10.1에서도 실행할 수 있습니다. Tomcat 9 및 WildFly 26 이하에는 이 WAR를 배포할 수 없습니다.
- 빌드: JDK 17 이상, Maven 3.9 이상.
- 프레임워크 없이 Servlet + JDBC 사용. APM 에이전트는 WAR에 포함하지 않습니다.

```sh
mvn --batch-mode verify
```

결과: `target/memoharbor.war`. 테스트는 임시 Tomcat 10.1에서 HTTP 등록·조회·삭제, SQLite 재시작 후 유지,
입력 검증, HTML 이스케이프, DB 파일 HTTP 접근 차단을 확인합니다.

## 배포

WildFly를 JDK 17 이상으로 시작한 뒤 관리 CLI로 WAR를 배포합니다. WAR 압축 해제 설정은 필요하지 않습니다.

```sh
"$JBOSS_HOME/bin/jboss-cli.sh" --connect --command='deploy /opt/projects/memoharbor/target/memoharbor.war --force'
```

Windows에서는 `bin/jboss-cli.bat`을 사용합니다. `WEB-INF/jboss-web.xml`이 컨텍스트 경로를 `/memoharbor`로 고정합니다. JDBC 드라이버는 WAR에 포함되어 별도 WildFly 모듈이나 datasource 등록이 필요하지 않습니다.

- 화면: `http://WILDFLY:8080/memoharbor/`
- DB 포함 상태 점검: `GET /memoharbor/health`
- 등록: `POST /memoharbor/create` (`title`, `detail` 폼 필드)
- 삭제: `POST /memoharbor/delete` (`id` 폼 필드)
- 인스턴스 표시: WildFly 시작 전에 `APM_INSTANCE_NAME=wildfly-1` 등으로 환경변수 설정. 미설정 시 `jboss.node.name`을 사용합니다.
- JDBC/애플리케이션 오류는 서버 로그에 기록합니다. 응답에는 `X-Request-ID`를 포함합니다.

## SQLite

WildFly 첫 실행 시 `${jboss.server.data.dir}/memoharbor/memoharbor.sqlite`가 자동 생성됩니다.
standalone 모드 기본 위치는 `$JBOSS_HOME/standalone/data/memoharbor/memoharbor.sqlite`입니다.
배포 디렉터리 밖에 저장하므로 WAR 재배포 후에도 데이터가 유지됩니다. `-Dmemoharbor.dataDir=/var/lib/memoharbor`로 저장 디렉터리를 지정할 수 있으며 이 설정이 우선합니다.
서버 실행 계정에 해당 디렉터리의 쓰기 권한이 필요합니다. DB 파일은 HTTP로 제공하지 않습니다.
SQLite 모드에서는 각 서버 인스턴스가 자기 DB를 사용합니다. MariaDB 설정은 아래를 참고하십시오. 한 WAS에 배포된 웹앱은 JVM 자원을 공유합니다.
신규 계정은 빈 목록으로 시작합니다. 기존 소유자 없는 데이터는 보존하지만 로그인 사용자에게 노출하지 않습니다. 화면은 최근 100건을 표시합니다.
기존 Tomcat의 SQLite 데이터를 이전하려면 서버를 중지하고 `WEB-INF/db/memoharbor.sqlite`와 관련 SQLite 파일을 새 저장 디렉터리에 복사한 뒤 시작하십시오. 자동 이전은 수행하지 않습니다.
Tomcat 10.1에서는 `memoharbor.dataDir` 지정이 권장됩니다. 미지정 시 기존 `WEB-INF/db`를 사용하므로 압축 해제된 웹앱이 필요하고 재배포 전에 백업해야 합니다.

## GitHub Release

`main`/PR에서 빌드·테스트를 수행하고 WAR를 Actions artifact로 보관합니다.
`v*` 태그를 푸시하면 검증을 통과한 WAR와 `SHA256SUMS`를 GitHub Release에 첨부합니다.
CI는 실제 WildFly 27.0.1에 WAR를 배포하여 로그인·등록·삭제, CSRF, DB/설정 파일 접근 차단 및 WAR 재배포 후 SQLite 데이터 유지를 확인합니다.

빌드 후 전용 로컬 WildFly 설치에서도 검증할 수 있습니다 (기본 HTTP/관리 포트 사용, Python 3 필요).

```sh
JBOSS_HOME=/opt/wildfly-27.0.1.Final bash scripts/verify-wildfly.sh
```

```sh
git tag v1.2.0
git push origin v1.2.0
```

앱별 회원가입·로그인 세션과 사용자별 데이터 분리를 지원합니다.

## 중앙 MariaDB 설정 (.env)

같은 프로젝트의 두 WAS 인스턴스는 같은 DB를 바라보도록 설정합니다.
A/B/C는 같은 MariaDB 서버를 사용하되 각각 `memoharbor`, `cataloggrove`, `taskpebble` DB를 사용합니다.
DB와 계정은 관리자 권한으로 먼저 생성하십시오. 앱은 시작할 때 데이터·계정·소유권 테이블을 준비합니다.

프로젝트 소스 루트에서 다음 파일을 만드십시오.

```sh
cp .env.example .env
```

```dotenv
DB_URL=jdbc:mariadb://DB_SERVER:3306/memoharbor
DB_USER=memoharbor
DB_PASSWORD='your-password'
```

WildFly는 Git 저장소 위치를 알 수 없으므로 `bin/standalone.conf`의 `JAVA_OPTS`에 프로젝트 `.env`의 절대 경로를 추가하십시오.
파일은 각 WAS VM에 있어야 하며, 실행 계정에 읽기 권한이 필요합니다.

```sh
JAVA_OPTS="$JAVA_OPTS -Dmemoharbor.env=/opt/projects/memoharbor/.env"
```

Windows `standalone.conf.bat`에서는 `set "JAVA_OPTS=%JAVA_OPTS% -Dmemoharbor.env=C:/projects/memoharbor/.env"`를 추가합니다. Domain 모드에서는 해당 서버 그룹의 JVM 시스템 속성으로 설정하십시오.

여러 앱을 같은 WAS에서 실행하면 앱별 `-Dmemoharbor.env=...`, `-Dcataloggrove.env=...`,
`-Dtaskpebble.env=...`를 함께 지정합니다. 각 옵션은 해당 앱에만 적용됩니다.
WildFly에서는 항상 외부 `.env` 경로를 지정하십시오. 실제 웹앱 경로가 제공되는 컨테이너에서는 웹앱 루트의 `.env`도 읽을 수 있지만, 압축된 WAR에서는 그 경로를 가정하지 않습니다.
웹앱 루트의 `.env`도 HTTP 접근이 차단됩니다. 재배포 시 덮어쓰지 않도록 외부 경로를 권장합니다.

- `.env` 없음: 기존 SQLite 모드.
- `.env` 있음: MariaDB 모드. 연결 실패·설정 누락 시 시작 실패하며 SQLite로 전환하지 않습니다.
- 명시한 `.env` 경로가 없음: 시작 실패.
- `.env` 변경 후 웹앱/WAS 재시작 필요.
- UTF-8 `KEY=value`, 주석 줄, 작은따옴표/큰따옴표로 감싼 값 지원. 변수 치환·여러 줄 값은 지원하지 않습니다.
- `.env`는 Git 및 WAR에서 제외합니다. `.env.example`만 공개합니다.
- 연결 시간 제한 5초, 소켓 시간 제한 10초. DB 세션 시간대는 UTC입니다.

예시 관리자 SQL (실제 비밀번호와 WAS 주소로 변경):

```sql
CREATE DATABASE IF NOT EXISTS memoharbor CHARACTER SET utf8mb4;
CREATE USER 'memoharbor'@'WAS_IP' IDENTIFIED BY 'your-password';
GRANT SELECT, INSERT, DELETE, CREATE ON memoharbor.* TO 'memoharbor'@'WAS_IP';
```

WAS 두 대에서 접속하려면 각 주소에 계정을 생성하거나 환경에 맞는 호스트 범위를 사용하십시오.
기존 SQLite 데이터는 자동으로 MariaDB에 복사되지 않습니다.

### MariaDB 검증

GitHub Actions는 실제 MariaDB 11.4 서비스를 띄워 두 임시 Tomcat 10.1 인스턴스 간 데이터 공유와 재시작을 검증합니다. WildFly HTTP 배포 검증은 SQLite를 사용합니다.
로컬에서 테스트할 때는 전용 테스트 DB의 `MARIADB_TEST_URL`, `MARIADB_TEST_USER`,
`MARIADB_TEST_PASSWORD` 환경변수를 설정하고 `mvn verify`를 실행하십시오.
미설정 시 MariaDB 통합 테스트는 건너뛰며 SQLite·설정 파서 테스트는 실행합니다.

## 로그인과 사용자별 데이터

- `GET /login`: 로그인·회원가입 화면. `POST /register`, `POST /login`, `POST /logout`: 폼 요청.
- 아이디는 영문 소문자·숫자·밑줄 3–40자, 비밀번호는 12–128자입니다. 앱마다 별도의 계정을 사용합니다.
- 비밀번호는 사용자별 무작위 salt와 PBKDF2-HMAC-SHA256 600,000회로 저장합니다.
- 로그인·회원가입 성공 시 기존 세션을 폐기하고 새 세션을 발급합니다. 유휴 30분 만료, 로그아웃 시 폐기합니다.
- JSESSIONID는 HttpOnly, 쿠키 전용입니다. 운영에서는 HTTPS를 사용하고 WAS의 세션 쿠키를 Secure 및 SameSite=Lax로 설정하십시오. 프록시를 사용할 때 WAS가 HTTPS 요청을 인식하도록 구성해야 합니다.
- 모든 POST는 화면의 `csrf` 필드가 필요합니다. 인증되지 않은 등록·삭제·로그아웃은 401, 토큰 오류는 403입니다. 홈 화면은 비로그인 시 로그인 화면으로 이동합니다.
- 조회와 삭제는 서버 세션의 사용자 ID로 제한됩니다. 다른 사용자의 ID로 삭제를 요청해도 404입니다. `/health`는 계속 공개합니다.
- 기존 `entries`는 변경하지 않고 `app_users`, `entry_owners` 및 조회 인덱스를 추가합니다. 기존 데이터는 자동으로 특정 사용자에게 배정하지 않습니다. 이전 데이터에 소유권을 배정하려면 백업 후 관리자가 검증된 사용자 ID로 `entry_owners(entry_id,user_id)`를 직접 등록하십시오.
- 같은 앱의 두 WAS는 MariaDB 계정·데이터를 공유하지만 세션은 각 WAS 메모리에 있습니다. 로드밸런서에는 sticky session이 필요하며, 장애 시 로그인 유지가 필요하면 WAS 세션 복제를 별도로 구성하십시오. 재시작 후에는 다시 로그인합니다.
- `mvn verify`는 실제 HTTP 세션, CSRF, 비밀번호 검증, 사용자 간 조회·삭제 차단, 재시작 후 데이터 유지 등을 검사합니다. MariaDB 테스트는 `MARIADB_TEST_*` 설정이 필요합니다.
