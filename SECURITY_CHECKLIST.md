# Pre-Public Upload Security Checklist

## ⚠️ CRITICAL - Do NOT Skip These Steps

### ✅ 1. Verify No Secrets in Code

Run these checks:

```bash
# Search for potential secrets
grep -r "api_key|apikey|secret|password|token" --include="*.dart" lib/

# Check for hardcoded values
grep -r "AIzaSy|AAAAA|sk-" --include="*.dart" lib/

# Verify google-services.json is excluded
git check-ignore android/app/google-services.json
```

### ✅ 2. Restrict Firebase API Key (CRITICAL)

**Do this BEFORE uploading to GitHub**

1. Go to Google Cloud Console: https://console.cloud.google.com/apis/credentials
2. Find API key ending in `VaZ-dc`
3. Click Edit
4. Set Application restrictions:
   - [x] Android apps
   - Add package: com.example.crypt_app
   - Add SHA-1 fingerprints (debug + release)
5. Set API restrictions:
   - [x] Firebase Installations API
   - [x] Cloud Firestore API
   - [x] Identity Toolkit API
   - [x] Token Service API
6. Save

### ✅ 3. Rotate Secrets (Optional but Recommended)

Create separate Firebase project for GitHub demo:

1. Create NEW Firebase project
2. Download NEW google-services.json
3. Use new project for GitHub demo
4. Keep original project for production

### ✅ 4. Verify .gitignore Works

```bash
# This should return the file path
git check-ignore android/app/google-services.json

# This should NOT show google-services.json
git status
```

### ✅ 5. Review Firestore Rules

Ensure rules don't expose sensitive data:

- Users can only read their own data
- Messages encrypted before storage
- No admin backdoors

### ✅ 6. Add Security Notice to README

Add this section:

```markdown
## Security Notice

⚠️ This is a demonstration project. 

- Firebase API keys are restricted but exposed
- Use for learning/portfolio only
- For production, implement additional security measures
```

### ✅ 7. Add LICENSE File

Create LICENSE file with MIT or Apache 2.0 license.

### ✅ 8. Final Verification

```bash
flutter clean
flutter pub get
flutter analyze
flutter build apk --debug
```

## 🎯 After Upload

1. Monitor Firebase Console for unauthorized usage
2. Enable Firebase App Check for production
3. Set up alerts for unusual activity
4. Add SECURITY.md for vulnerability reporting

## 🚨 Emergency Response

If secrets are accidentally exposed:

1. Immediately revoke API keys in Google Cloud Console
2. Delete repository or use git filter-branch to remove secrets
3. Create new Firebase project
4. Generate new keys
5. Never commit secrets again
