//
//  AppUpdateInstaller.swift
//  ButteryUpdater
//
//  Bundle-based install: extract zip → validate signature → strip quarantine →
//  atomically swap target .app with staged .app, escalating to admin when the
//  target's parent is not user-writable. Writes a rollback marker so the next
//  launch can confirm success.
//

import Foundation
import Logging
#if canImport(Security)
import Security
#endif

/// Performs the file-system side of an update install for a `.app` bundle.
///
/// This type is intentionally not an actor — its methods are synchronous, and
/// it is owned by `AppUpdateService` (which is the actor). All file paths are
/// validated explicitly; nothing here force-unwraps Bundle.main.
public struct AppUpdateInstaller: Sendable {
	public let appName: String
	public let logger: Logger

	public init(appName: String, logger: Logger) {
		self.appName = appName
		self.logger = logger
	}

	// MARK: - Working directory

	/// Per-app working directory for staging downloads + extractions.
	public var workingDirectory: URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
		return base
			.appendingPathComponent("ButteryUpdater", isDirectory: true)
			.appendingPathComponent(appName, isDirectory: true)
	}

	public func ensureWorkingDirectory() throws -> URL {
		let dir = workingDirectory
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	/// Wipe the staging directory (idempotent).
	public func cleanupStaging() {
		let staging = workingDirectory.appendingPathComponent("staging", isDirectory: true)
		try? FileManager.default.removeItem(at: staging)
	}

	// MARK: - Translocation guard

	/// macOS launches downloaded apps from a read-only translocation mount,
	/// shadowing the original location. Replacing the bundle from there is a
	/// no-op the user won't notice. Refuse and tell them to move the app.
	public func ensureNotTranslocated(currentBundle: URL) throws {
		let path = currentBundle.path
		if path.contains("/AppTranslocation/") {
			throw AppUpdateError.translocated(path)
		}
	}

	// MARK: - Stage extraction

	/// Extract a zipped `.app` bundle to a staging directory.
	///
	/// Uses `/usr/bin/ditto` which preserves bundle resource forks / xattrs.
	/// Returns the URL of the extracted top-level `.app`.
	public func stageBundle(from zipPath: URL, expectedBundleName: String) throws -> URL {
		let working = try ensureWorkingDirectory()
		let staging = working.appendingPathComponent("staging", isDirectory: true)
		// Always start from a clean staging slate.
		try? FileManager.default.removeItem(at: staging)
		try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
		process.arguments = ["-x", "-k", zipPath.path, staging.path]

		let stderrPipe = Pipe()
		process.standardError = stderrPipe
		process.standardOutput = Pipe()

		do {
			try process.run()
		} catch {
			throw AppUpdateError.extractionFailed("ditto launch failed: \(error.localizedDescription)")
		}
		process.waitUntilExit()

		guard process.terminationStatus == 0 else {
			let msg = readStderr(stderrPipe) ?? "exit \(process.terminationStatus)"
			throw AppUpdateError.extractionFailed("ditto failed: \(msg)")
		}

		let extracted = staging.appendingPathComponent(expectedBundleName, isDirectory: true)
		guard FileManager.default.fileExists(atPath: extracted.path) else {
			// Search shallowly for any .app at the staging root as a fallback.
			let entries = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
			let app = entries.first(where: { $0.hasSuffix(".app") })
			if let app {
				return staging.appendingPathComponent(app, isDirectory: true)
			}
			throw AppUpdateError.extractionFailed("Expected \(expectedBundleName) inside the zip; found: \(entries.joined(separator: ", "))")
		}
		return extracted
	}

	// MARK: - Quarantine

	/// Strip `com.apple.quarantine` (and any sibling quarantine attrs) recursively.
	///
	/// macOS sets this xattr on anything written via URLSession/curl/etc. If left
	/// in place, Gatekeeper prompts on every launch.
	public func stripQuarantine(at bundlePath: URL) throws {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
		process.arguments = ["-dr", "com.apple.quarantine", bundlePath.path]
		process.standardError = Pipe()
		process.standardOutput = Pipe()
		do {
			try process.run()
		} catch {
			// Non-fatal: log and continue. Lack of xattr is fine.
			logger.warning("xattr launch failed: \(error.localizedDescription)")
			return
		}
		process.waitUntilExit()
		// xattr exits non-zero if the attribute didn't exist, which is fine.
		if process.terminationStatus != 0 {
			logger.debug("xattr -dr returned \(process.terminationStatus) (likely no quarantine attr present)")
		}
	}

	// MARK: - Code signature

	/// Validate the staged bundle's code signature using `SecStaticCode`.
	///
	/// Verifies that the bundle is properly signed and (optionally) that its
	/// designated requirement matches the currently running bundle's signing
	/// identity. Mismatched signers indicate a swapped/tampered binary — refuse.
	public func verifySignature(at bundlePath: URL, matchingBundle reference: URL?) throws {
		#if canImport(Security)
		// If we're a dev build (running from an unsigned bundle), don't insist
		// on a stricter check for the staged bundle than we have ourselves.
		// In production both reference and staged are signed, and strict
		// validation runs end-to-end. In a local dev loop both are unsigned
		// and we skip — otherwise unsigned dev builds could never install
		// their own updates. A signed-but-broken reference is treated the
		// same as unsigned (conservative).
		if let reference, !isSigned(at: reference) {
			logger.warning("Reference bundle at \(reference.path) is unsigned or signature-invalid; skipping strict validation on staged bundle")
			return
		}

		var staticCode: SecStaticCode?
		let createStatus = SecStaticCodeCreateWithPath(bundlePath as CFURL, [], &staticCode)
		guard createStatus == errSecSuccess, let staticCode else {
			throw AppUpdateError.signatureInvalid("SecStaticCodeCreate failed: \(createStatus)")
		}

		// kSecCSStrictValidate (1<<13) | kSecCSCheckAllArchitectures (1<<14)
		// | kSecCSCheckNestedCode (1<<3). Use raw bits so this compiles
		// regardless of whether the SDK names them as OptionSet members.
		let flags = SecCSFlags(rawValue: (1 << 13) | (1 << 14) | (1 << 3))
		var errors: Unmanaged<CFError>?
		let validateStatus = SecStaticCodeCheckValidityWithErrors(staticCode, flags, nil, &errors)
		if validateStatus != errSecSuccess {
			let err = errors?.takeRetainedValue()
			let desc = err.map { CFErrorCopyDescription($0) as String } ?? "OSStatus \(validateStatus)"
			throw AppUpdateError.signatureInvalid(desc)
		}

		// If a reference bundle is provided, require designated-requirement match
		// so a valid-but-different signer cannot replace us.
		if let reference {
			var refCode: SecStaticCode?
			let refStatus = SecStaticCodeCreateWithPath(reference as CFURL, [], &refCode)
			guard refStatus == errSecSuccess, let refCode else {
				logger.warning("Could not load reference signature from \(reference.path); skipping signer pin")
				return
			}
			var refRequirement: SecRequirement?
			let reqStatus = SecCodeCopyDesignatedRequirement(refCode, [], &refRequirement)
			guard reqStatus == errSecSuccess, let refRequirement else {
				logger.warning("Could not derive reference designated requirement: \(reqStatus); skipping signer pin")
				return
			}
			var pinErrors: Unmanaged<CFError>?
			let pinStatus = SecStaticCodeCheckValidityWithErrors(staticCode, flags, refRequirement, &pinErrors)
			if pinStatus != errSecSuccess {
				let err = pinErrors?.takeRetainedValue()
				let desc = err.map { CFErrorCopyDescription($0) as String } ?? "OSStatus \(pinStatus)"
				throw AppUpdateError.signatureInvalid("Signer mismatch: \(desc)")
			}
		}
		#else
		// Non-Apple platforms: skip signature validation.
		_ = bundlePath; _ = reference
		#endif
	}

	/// Returns true if the bundle at `url` is signed and the signature
	/// passes basic (non-strict) validation. Used to decide whether to
	/// enforce strict validation on a candidate replacement.
	public func isSigned(at url: URL) -> Bool {
		#if canImport(Security)
		var code: SecStaticCode?
		guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
			return false
		}
		return SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
		#else
		_ = url
		return false
		#endif
	}

	// MARK: - Install (atomic swap with optional escalation)

	/// Atomically swap `targetBundle` with the staged bundle.
	///
	/// - If the parent directory is user-writable, uses `FileManager.replaceItem`,
	///   which handles same- and cross-volume swaps and produces a backup.
	/// - Otherwise, escalates via AppleScript (`osascript … with administrator
	///   privileges`) and runs an inline shell script. If the user cancels the
	///   admin prompt, throws `.userCancelled`.
	///
	/// Writes a rollback marker on success.
	public func installBundle(
		staged: URL,
		target: URL,
		expectedVersion: String
	) throws {
		let parent = target.deletingLastPathComponent()
		let backup = parent.appendingPathComponent(".\(target.lastPathComponent).backup", isDirectory: true)

		// Clean any stale backup before installing.
		if FileManager.default.fileExists(atPath: backup.path) {
			try? FileManager.default.removeItem(at: backup)
		}

		let parentWritable = FileManager.default.isWritableFile(atPath: parent.path)
		if parentWritable {
			try installUnprivileged(staged: staged, target: target, backup: backup)
		} else {
			try installPrivileged(staged: staged, target: target, backup: backup)
		}

		// Persist marker so the next launch can clean up the backup once we
		// confirm we're running the new version.
		do {
			let marker = UpdateMarker(
				appName: appName,
				expectedVersion: expectedVersion,
				backupPath: backup.path,
				installedAt: Date()
			)
			try marker.write()
		} catch {
			logger.warning("Failed to write update marker: \(error.localizedDescription) — install succeeded but rollback metadata is missing")
		}
	}

	private func installUnprivileged(staged: URL, target: URL, backup: URL) throws {
		let fm = FileManager.default
		// `FileManager.replaceItem` does an atomic rename on the same volume and
		// drops the original — so we'd lose the rollback. Do the swap explicitly.
		do {
			try fm.moveItem(at: target, to: backup)
		} catch {
			throw AppUpdateError.installFailed("Could not back up current bundle: \(error.localizedDescription)")
		}
		do {
			try fm.moveItem(at: staged, to: target)
		} catch {
			// Best-effort rollback so the user is left with a working app.
			try? fm.moveItem(at: backup, to: target)
			throw AppUpdateError.installFailed("Could not install new bundle: \(error.localizedDescription)")
		}
		logger.info("Installed bundle at \(target.path)")
	}

	private func installPrivileged(staged: URL, target: URL, backup: URL) throws {
		// Build a single-line shell script. We avoid embedded newlines because
		// AppleScript's parsing of literal newlines inside `"..."` string
		// literals isn't reliably portable across macOS releases — `;`
		// separators sidestep that entirely.
		//
		// Failure handling:
		// - `set -e` causes the script to abort on any unhandled non-zero exit.
		// - The `[ -e backup ] && rm` form is safe under `set -e`: a failing
		//   command that's a non-final element of an `&&` list does NOT trigger
		//   the immediate exit (bash only honours the last command in a list).
		// - The second `mv` is the dangerous one — if it fails after the first
		//   `mv` already moved the live bundle aside, we'd be left with no app
		//   at the target. The `|| { mv backup target; exit 1; }` fallback puts
		//   the original bundle back. The `||` left side is also a non-final
		//   position, so its failure is tolerated by `set -e` long enough to
		//   reach the rollback block.
		//
		// Ownership: chown -R sets the new bundle to match parent dir ownership
		// (typically root:admin for /Applications). This corrects ownership
		// after an unprivileged-source mv — the bundle was user-owned in
		// staging. macOS POSIX permissions are preserved by mv. Extended ACLs
		// inherited from the parent are not propagated — chown -R doesn't do
		// that, and `/Applications` doesn't typically carry inheritable ACLs in
		// default installs. Corporate-managed Macs with special ACLs on
		// `/Applications` are out of scope; the bundle still launches because
		// it remains world-readable.
		let parts: [String] = [
			"set -e",
			"[ -e \(shellQuote(backup.path)) ] && /bin/rm -rf \(shellQuote(backup.path))",
			"/bin/mv \(shellQuote(target.path)) \(shellQuote(backup.path))",
			"/bin/mv \(shellQuote(staged.path)) \(shellQuote(target.path)) || { /bin/mv \(shellQuote(backup.path)) \(shellQuote(target.path)); exit 1; }",
			"PARENT_OWN=$(/usr/bin/stat -f %u:%g \(shellQuote(target.deletingLastPathComponent().path)))",
			"/usr/sbin/chown -R \"$PARENT_OWN\" \(shellQuote(target.path)) 2>/dev/null || true",
			"exit 0",
		]
		let script = parts.joined(separator: "; ")

		// AppleScript-quote the script. AppleScript strings use double quotes
		// and escape backslashes + double quotes.
		let appleQuoted = "\"" + script
			.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "\"", with: "\\\"")
			+ "\""

		let appleScript = "do shell script \(appleQuoted) with administrator privileges"

		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
		process.arguments = ["-e", appleScript]

		let stderrPipe = Pipe()
		process.standardError = stderrPipe
		process.standardOutput = Pipe()

		do {
			try process.run()
		} catch {
			throw AppUpdateError.permissionDenied("osascript launch failed: \(error.localizedDescription)")
		}
		process.waitUntilExit()

		guard process.terminationStatus == 0 else {
			let msg = readStderr(stderrPipe) ?? ""
			// AppleScript error -128 is user-cancelled (e.g. dismissed the auth dialog).
			if msg.contains("-128") || msg.localizedCaseInsensitiveContains("cancel") {
				throw AppUpdateError.userCancelled
			}
			throw AppUpdateError.permissionDenied("Privileged install failed: \(msg.isEmpty ? "exit \(process.terminationStatus)" : msg)")
		}
		logger.info("Installed bundle at \(target.path) (privileged)")
	}

	// MARK: - Rollback / confirmation

	/// Called on successful launch of the new version. Removes the backup and
	/// clears the marker. If the marker exists but the version doesn't match,
	/// keeps the backup so the user can roll back manually.
	public func confirmRunningVersion(_ runningVersion: String) {
		guard let marker = UpdateMarker.read(appName: appName) else { return }
		if marker.expectedVersion == runningVersion {
			let backup = URL(fileURLWithPath: marker.backupPath)
			if FileManager.default.fileExists(atPath: backup.path) {
				do {
					try FileManager.default.removeItem(at: backup)
					logger.info("Cleared update backup at \(backup.path)")
				} catch {
					logger.warning("Could not remove backup at \(backup.path): \(error.localizedDescription)")
				}
			}
			UpdateMarker.clear(appName: appName)
		} else {
			logger.warning("Update marker version (\(marker.expectedVersion)) does not match running version (\(runningVersion)); preserving backup at \(marker.backupPath)")
		}
	}

	// MARK: - Helpers

	/// Wrap a path in single quotes for /bin/sh, escaping any embedded single quotes.
	private func shellQuote(_ s: String) -> String {
		"'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
	}

	/// Drain a pipe's read end and decode it as UTF-8 text. Returns nil for
	/// empty/binary output so callers can fall back to a synthetic error string.
	private func readStderr(_ pipe: Pipe) -> String? {
		let bytes = (try? pipe.fileHandleForReading.readToEnd()) ?? nil
		guard let bytes, !bytes.isEmpty else { return nil }
		let text = String(data: bytes, encoding: .utf8)?
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return (text?.isEmpty == false) ? text : nil
	}
}
