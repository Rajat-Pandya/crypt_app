#!/bin/bash
# Safe Cleanup Script for Crypt App
# 
# WARNING: Run this script only after thorough testing!
# This script moves deprecated files to a backup location
# rather than deleting them immediately.

set -e

echo "[CLEANUP] Starting safe cleanup process..."
echo "[CLEANUP] This will move deprecated files to backup/ directory"
echo ""

# Create backup directory
mkdir -p backup/services
mkdir -p backup/screens
mkdir -p backup/blocs

echo "[CLEANUP] Step 1: Backing up deprecated services..."

# Move old encryption service (replaced by device_encryption_service.dart)
if [ -f "lib/services/encryption_service.dart" ]; then
    echo "  Moving encryption_service.dart -> backup/"
    mv lib/services/encryption_service.dart backup/services/
fi

# Move old startup service (replaced by v2)
if [ -f "lib/services/encryption_startup_service.dart" ]; then
    echo "  Moving encryption_startup_service.dart -> backup/"
    mv lib/services/encryption_startup_service.dart backup/services/
fi

# Move duplicate reconnect manager
if [ -f "lib/services/reconnect_manager.dart" ]; then
    echo "  Moving reconnect_manager.dart -> backup/"
    mv lib/services/reconnect_manager.dart backup/services/
fi

echo "[CLEANUP] Step 2: Backing up deprecated screens..."

# Move old number guess screen (has _fixed version)
if [ -f "lib/screens/number_guess_screen.dart" ]; then
    echo "  Moving number_guess_screen.dart -> backup/"
    mv lib/screens/number_guess_screen.dart backup/screens/
fi

echo "[CLEANUP] Step 3: Cleaning up unused imports..."

# Run dart fix to remove unused imports
echo "  Running dart fix..."
dart fix --apply || true

echo "[CLEANUP] Step 4: Analyzing for remaining issues..."

dart analyze lib/ 2>&1 | head -50

echo ""
echo "[CLEANUP] Backup complete!"
echo "[CLEANUP] Deprecated files moved to backup/ directory"
echo "[CLEANUP] If app works correctly, you can delete backup/ directory"
echo ""
echo "[CLEANUP] Next steps:"
echo "  1. Test the app thoroughly"
echo "  2. If everything works: rm -rf backup/"
echo "  3. If issues found: restore from backup/"
