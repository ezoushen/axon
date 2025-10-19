# GitHub App Setup for Automated Releases

The release workflow requires a GitHub App to push to both the main repository and the homebrew-tap submodule repository. This guide shows you how to create and configure the GitHub App.

## Why a GitHub App?

The default `GITHUB_TOKEN` only has permissions for the repository where the workflow runs. Since we need to push to both `axon` and `homebrew-axon` repositories, we need a GitHub App with access to both.

## Step 1: Create a GitHub App

1. Go to your GitHub profile → Settings → Developer settings → GitHub Apps
   - Or visit: https://github.com/settings/apps

2. Click "New GitHub App"

3. Fill in the basic information:
   - **GitHub App name**: `AXON Release Bot` (or any name you prefer)
   - **Homepage URL**: `https://github.com/ezoushen/axon`
   - **Webhook**: Uncheck "Active" (we don't need webhooks)

4. Set Repository Permissions:
   - **Contents**: Read and write
   - **Metadata**: Read-only (automatically set)

5. Set "Where can this GitHub App be installed?":
   - Select "Only on this account"

6. Click "Create GitHub App"

## Step 2: Generate Private Key

1. After creating the app, scroll down to "Private keys"
2. Click "Generate a private key"
3. A `.pem` file will be downloaded - keep this safe!

## Step 3: Install the App on Your Repositories

1. On the GitHub App page, click "Install App" in the left sidebar
2. Select your account (ezoushen)
3. Choose "Only select repositories"
4. Select:
   - `axon`
   - `homebrew-axon`
5. Click "Install"

## Step 4: Get the App ID

1. Go back to your GitHub App settings
2. Note the "App ID" (you'll see it at the top)
   - Example: `123456`

## Step 5: Add Secrets to Your Repository

1. Go to your `axon` repository
2. Go to Settings → Secrets and variables → Actions
3. Click "New repository secret"

4. Add the first secret:
   - **Name**: `APP_ID`
   - **Value**: Your App ID (e.g., `123456`)
   - Click "Add secret"

5. Add the second secret:
   - **Name**: `APP_PRIVATE_KEY`
   - **Value**: Open the `.pem` file you downloaded and paste the entire contents (including the `-----BEGIN RSA PRIVATE KEY-----` and `-----END RSA PRIVATE KEY-----` lines)
   - Click "Add secret"

## Step 6: Verify the Setup

Your secrets page should now show:
- `APP_ID`
- `APP_PRIVATE_KEY`

## Testing

The next time you create a release:

```bash
./release/create-release.sh
# Enter version: 0.2.0
# Push to GitHub? y
```

The GitHub Actions workflow will:
1. Generate a token using your GitHub App
2. Use that token to push to both repositories
3. Update the Homebrew formula automatically

## Troubleshooting

### Error: "Resource not accessible by integration"

**Solution**: Make sure the GitHub App has:
- "Contents: Read and write" permission
- Is installed on both `axon` and `homebrew-axon` repositories

### Error: "Bad credentials"

**Solution**:
- Verify `APP_PRIVATE_KEY` contains the full private key including header/footer
- Verify `APP_ID` is correct
- Regenerate the private key if needed

### Error: "App installation not found"

**Solution**: Make sure the app is installed on both repositories in Step 3

## Security Notes

- **Never commit** the `.pem` file to the repository
- The private key is stored securely in GitHub Secrets
- The generated token expires after 1 hour
- The token is only used during the workflow execution

## Revoking Access

If you need to revoke the app's access:
1. Go to Settings → Developer settings → GitHub Apps
2. Select your app
3. Click "Advanced" → "Delete GitHub App"

Or to just remove from specific repositories:
1. Go to Settings → Integrations → Applications
2. Find your app → Configure
3. Remove the repository access
