#!/usr/bin/env python3
"""
16KB Page Size Alignment Checker for Android App Bundles (AAB)

This script extracts and analyzes native libraries (.so files) from an Android App Bundle
to verify they meet Google Play's 16KB page size alignment requirement for Android 15+.

Usage:
    python3 tools/check_page_size_alignment.py build/app/outputs/bundle/release/app-release.aab

Requirements:
    - Python 3.6+
    - readelf command (from binutils, usually pre-installed on macOS/Linux)
    - unzip command (pre-installed on macOS/Linux)
"""

import sys
import os
import subprocess
import tempfile
import shutil
import zipfile
from pathlib import Path
from typing import List, Tuple, Dict

# ANSI color codes for terminal output
class Colors:
    HEADER = '\033[95m'
    OKBLUE = '\033[94m'
    OKCYAN = '\033[96m'
    OKGREEN = '\033[92m'
    WARNING = '\033[93m'
    FAIL = '\033[91m'
    ENDC = '\033[0m'
    BOLD = '\033[1m'
    UNDERLINE = '\033[4m'

def print_header(message: str):
    """Print formatted header"""
    print(f"\n{Colors.HEADER}{Colors.BOLD}{'='*80}{Colors.ENDC}")
    print(f"{Colors.HEADER}{Colors.BOLD}{message}{Colors.ENDC}")
    print(f"{Colors.HEADER}{Colors.BOLD}{'='*80}{Colors.ENDC}\n")

def print_success(message: str):
    """Print success message"""
    print(f"{Colors.OKGREEN}✅ {message}{Colors.ENDC}")

def print_warning(message: str):
    """Print warning message"""
    print(f"{Colors.WARNING}⚠️  {message}{Colors.ENDC}")

def print_error(message: str):
    """Print error message"""
    print(f"{Colors.FAIL}❌ {message}{Colors.ENDC}")

def print_info(message: str):
    """Print info message"""
    print(f"{Colors.OKCYAN}ℹ️  {message}{Colors.ENDC}")

def check_dependencies():
    """Check if required tools are available"""
    print_info("Checking dependencies...")
    
    # Check for readelf, including Homebrew's keg-only location
    readelf_path = shutil.which('readelf')
    if not readelf_path:
        # Check Homebrew keg-only location on macOS
        homebrew_readelf = '/opt/homebrew/opt/binutils/bin/readelf'
        if os.path.exists(homebrew_readelf):
            readelf_path = homebrew_readelf
    
    if readelf_path:
        print_success(f"readelf found at {readelf_path}")
    else:
        print_error("readelf not found")
        print_info("On macOS, install with: brew install binutils")
        print_info("On Ubuntu/Debian, install with: sudo apt-get install binutils")
        return False, None
    
    # Check for unzip
    unzip_path = shutil.which('unzip')
    if unzip_path:
        print_success(f"unzip found at {unzip_path}")
    else:
        print_error("unzip not found")
        return False, None
    
    return True, readelf_path

def extract_aab(aab_path: str, extract_dir: str) -> bool:
    """Extract AAB file to temporary directory"""
    try:
        print_info(f"Extracting AAB: {aab_path}")
        with zipfile.ZipFile(aab_path, 'r') as zip_ref:
            zip_ref.extractall(extract_dir)
        print_success(f"Extracted to: {extract_dir}")
        return True
    except Exception as e:
        print_error(f"Failed to extract AAB: {e}")
        return False

def find_native_libraries(extract_dir: str) -> List[Path]:
    """Find all .so files in extracted AAB"""
    so_files = []
    base_path = Path(extract_dir)
    
    # Look in base/ directory which contains the main module
    base_module = base_path / "base"
    if base_module.exists():
        so_files.extend(base_module.rglob("*.so"))
    
    # Also check other module directories
    for item in base_path.iterdir():
        if item.is_dir() and item.name != "base":
            so_files.extend(item.rglob("*.so"))
    
    return sorted(so_files)

def check_library_alignment(so_path: Path, readelf_path: str = 'readelf') -> Tuple[bool, int, Dict]:
    """
    Check if a native library has proper 16KB page alignment.
    
    Returns:
        Tuple of (is_compliant, max_alignment, details_dict)
    """
    try:
        # Run readelf to get program headers
        result = subprocess.run(
            [readelf_path, '-l', str(so_path)],
            capture_output=True,
            text=True,
            check=True
        )
        
        output = result.stdout
        max_alignment = 0
        segments = []
        
        # Parse readelf output for LOAD segments
        in_program_headers = False
        for line in output.split('\n'):
            if 'Program Headers:' in line:
                in_program_headers = True
                continue
            
            if in_program_headers and 'LOAD' in line:
                parts = line.split()
                try:
                    # Find alignment value (usually the last hex value in the line)
                    for part in reversed(parts):
                        if part.startswith('0x'):
                            alignment = int(part, 16)
                            max_alignment = max(max_alignment, alignment)
                            segments.append({
                                'type': 'LOAD',
                                'alignment': alignment
                            })
                            break
                except (ValueError, IndexError):
                    continue
        
        # 16KB = 16384 bytes = 0x4000
        required_alignment = 16384
        is_compliant = max_alignment >= required_alignment
        
        details = {
            'max_alignment': max_alignment,
            'required_alignment': required_alignment,
            'segments': segments,
            'output': output
        }
        
        return is_compliant, max_alignment, details
        
    except subprocess.CalledProcessError as e:
        print_error(f"Failed to run readelf on {so_path.name}: {e}")
        return False, 0, {}
    except Exception as e:
        print_error(f"Error checking {so_path.name}: {e}")
        return False, 0, {}

def format_size(size_bytes: int) -> str:
    """Format byte size in human-readable format"""
    if size_bytes >= 16384:
        return f"{size_bytes} bytes ({size_bytes // 1024}KB)"
    else:
        return f"{size_bytes} bytes"

def analyze_aab(aab_path: str):
    """Main analysis function"""
    print_header(f"16KB Page Size Alignment Check")
    print_info(f"Analyzing: {aab_path}\n")
    
    # Check if AAB exists
    if not os.path.exists(aab_path):
        print_error(f"AAB file not found: {aab_path}")
        print_info("Build your release AAB first with: flutter build appbundle")
        return False
    
    # Check dependencies
    deps_ok, readelf_path = check_dependencies()
    if not deps_ok:
        return False
    
    # Create temporary directory for extraction
    with tempfile.TemporaryDirectory() as temp_dir:
        # Extract AAB
        if not extract_aab(aab_path, temp_dir):
            return False
        
        # Find native libraries
        print_info("Searching for native libraries...")
        so_files = find_native_libraries(temp_dir)
        
        if not so_files:
            print_warning("No native libraries found in AAB")
            print_info("This might be a Dart-only app without native dependencies")
            return True
        
        print_success(f"Found {len(so_files)} native libraries\n")
        
        # Analyze each library
        print_header("Analysis Results")
        
        compliant_libs = []
        non_compliant_libs = []
        
        for so_file in so_files:
            relative_path = so_file.relative_to(temp_dir)
            file_size = so_file.stat().st_size
            print(f"\n{Colors.BOLD}Library:{Colors.ENDC} {relative_path}")
            print(f"  Size: {file_size:,} bytes")
            
            is_compliant, max_alignment, details = check_library_alignment(so_file, readelf_path)
            
            if is_compliant:
                compliant_libs.append((relative_path, max_alignment))
                print_success(f"  Alignment: {format_size(max_alignment)} - COMPLIANT ✅")
            else:
                non_compliant_libs.append((relative_path, max_alignment))
                print_error(f"  Alignment: {format_size(max_alignment)} - NON-COMPLIANT ❌")
                print_warning(f"  Required: {format_size(16384)} (16KB)")
        
        # Summary
        print_header("Summary")
        
        total = len(so_files)
        compliant_count = len(compliant_libs)
        non_compliant_count = len(non_compliant_libs)
        
        print(f"Total libraries analyzed: {total}")
        print_success(f"Compliant (16KB aligned): {compliant_count}")
        
        if non_compliant_count > 0:
            print_error(f"Non-compliant (4KB aligned): {non_compliant_count}")
        
        # Detailed breakdown
        if non_compliant_libs:
            print_header("❌ Non-Compliant Libraries (CRITICAL)")
            print_error("These libraries will cause Google Play rejection for Android 15+ apps:")
            print()
            
            for lib_path, alignment in non_compliant_libs:
                print(f"  • {lib_path}")
                print(f"    Current alignment: {format_size(alignment)}")
                print(f"    Required alignment: 16384 bytes (16KB)")
                
                # Try to identify the source
                lib_name = lib_path.name
                if 'sceneview' in lib_name or 'filament' in lib_name:
                    print(f"    {Colors.WARNING}Source: SceneView/Filament library{Colors.ENDC}")
                    print(f"    {Colors.WARNING}Action: Contact io.github.sceneview maintainers{Colors.ENDC}")
                elif 'arcore' in lib_name or 'arsceneview' in lib_name:
                    print(f"    {Colors.WARNING}Source: ARCore/ARSceneView SDK{Colors.ENDC}")
                    print(f"    {Colors.WARNING}Action: Update to ARCore 1.45+ or contact Google{Colors.ENDC}")
                else:
                    print(f"    {Colors.WARNING}Source: Unknown - check dependencies{Colors.ENDC}")
                print()
        
        if compliant_libs:
            print_header("✅ Compliant Libraries")
            for lib_path, alignment in compliant_libs:
                print(f"  • {lib_path} ({format_size(alignment)})")
        
        # Final verdict
        print_header("Verdict")
        
        if non_compliant_count == 0:
            print_success("🎉 All native libraries are 16KB aligned!")
            print_success("Your app should pass Google Play's 16KB page size validation.")
            return True
        else:
            print_error("⚠️  Your app has non-compliant native libraries!")
            print_error("Google Play will REJECT this app for Android 15+ submissions.")
            print()
            print_info("Next Steps:")
            print("  1. Update ARCore to latest version (1.45.0+)")
            print("  2. Check for SceneView library updates")
            print("  3. Contact library maintainers if updates unavailable")
            print("  4. Consider switching to alternative AR frameworks")
            print()
            print_info("Reference:")
            print("  • https://developer.android.com/guide/practices/page-sizes")
            print("  • https://android-developers.googleblog.com/2023/10/16kb-page-size-support.html")
            return False

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 tools/check_page_size_alignment.py <path-to-aab>")
        print()
        print("Example:")
        print("  python3 tools/check_page_size_alignment.py build/app/outputs/bundle/release/app-release.aab")
        sys.exit(1)
    
    aab_path = sys.argv[1]
    success = analyze_aab(aab_path)
    
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
