# AI EXAM · 공인중개사 7과목 AI 학습 플랫폼 (GitHub Pages용)

모든 파일이 **한 폴더**에 있습니다. 이 폴더 안의 파일을 GitHub 저장소에 그대로 올리면 됩니다.

## 파일 구성

| 파일 | 내용 |
|---|---|
| `index.html` | 첫 화면 — 학생 이름, 내 학습 폴더 요약, **과목별 모의고사 링크** |
| `signup.html` | **회원가입** (학생 / 교수) — 아이디가 곧 학생 폴더 이름 |
| `auth.html` | 로그인 |
| `my.html` | 내 폴더 (`아이디/과목/시험기록`, `아이디/과목/생성모의고사`) |
| `admin.html` | 관리자 — 교수 승인, 회원 관리, 학생 폴더 열람 |
| `real-estate-intro.html` | 부동산학개론 |
| `real-estate-law.html` | 민법 및 민사특별법 |
| `brokerage-practice.html` | 공인중개사법령 및 중개실무 |
| `real-estate-public-law.html` | 부동산공법 |
| `public-notice-law.html` | 부동산공시법령 |
| `real-estate-tax.html` | 부동산세법 |
| `appraisal-theory.html` | 감정평가론 |
| `config.js` | ★ Supabase 주소·키 입력 (이 파일만 수정) |
| `auth.js` | 모든 페이지가 함께 쓰는 로그인·저장 모듈 (수정 불필요) |
| `favicon.svg`, `.nojekyll` | 아이콘, GitHub Pages 설정용 빈 파일 |
| `aiexam_schema.sql` | Supabase SQL Editor에서 1회 실행할 DB 코드 (사이트 동작에는 불필요) |

## 올리는 방법

1. GitHub에서 **New repository**를 만듭니다(Public).
2. **Add file → Upload files**에서 이 폴더 안의 파일을 **전부** 끌어다 놓고 **Commit changes**를 누릅니다.
3. **Settings → Pages**에서 Branch를 `main` / `(root)`로 선택하고 **Save**를 누릅니다.
4. 1~2분 뒤 `https://<계정>.github.io/<저장소>/`로 접속합니다.

## DB 설정 (처음 한 번)

1. supabase.com에서 새 프로젝트를 만듭니다(Region: Seoul).
2. **SQL Editor**에 `aiexam_schema.sql` 전체를 붙여넣고 **Run**을 누릅니다.
3. **Project Settings → API Keys**에서 Project URL과 anon(또는 publishable) 키를 복사합니다.
4. 복사한 두 값을 `config.js`에 넣고 커밋합니다. service_role 키는 절대 넣지 마세요.
5. 관리자를 지정합니다. `signup.html`에서 학생으로 가입한 뒤, SQL Editor에서 아래 문장을 실행합니다.
   ```sql
   update ax.users set role = 'admin', status = 'active', subject_id = null where username = '내아이디';
   ```

## 학생 폴더

학생이 시험을 제출하거나 AI 모의고사를 생성하면 자동으로 저장됩니다.

```
choi_2026/
  └─ 부동산학개론/
      ├─ 시험기록/20261028-113133-262_[1주차]_기출문제_실전_모의고사.json
      └─ 생성모의고사/20261028-..._AI_적중_예상모의.json
```

GitHub Pages는 서버에 폴더를 만들 수 없어서, 학생 폴더는 Supabase DB에 위 경로 그대로 저장합니다. `my.html`의 **폴더 전체 내려받기(ZIP)**를 누르면 같은 구조의 실제 폴더로 받을 수 있습니다.
