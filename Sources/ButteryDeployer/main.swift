//
//  main.swift
//  buttery-deployer
//
//  Headless sidecar that watches for new Docker-based releases
//  and auto-deploys them via docker compose.
//
//  Environment variables:
//    SERVER_BASE_URL     - ButteryAI-Server URL (required)
//    APP_NAME            - App to watch (default: butteryai-server)
//    CHECK_INTERVAL      - Seconds between checks (default: 300)
//    COMPOSE_FILE        - Path to docker-compose file (default: /opt/butteryai/docker-compose.production.yml)
//    COMPOSE_SERVICE     - Docker compose service name (default: app)
//    CURRENT_VERSION     - Override current version (default: 0.0.0)

import ButteryUpdater
import Foundation
import Logging

@main
struct ButteryDeployer {
	static func main() async {
		let logger = Logger(label: "buttery-deployer")

		let serverBaseURL = ProcessInfo.processInfo.environment["SERVER_BASE_URL"] ?? ""
		let appName = ProcessInfo.processInfo.environment["APP_NAME"] ?? "butteryai-server"
		let checkInterval = ProcessInfo.processInfo.environment["CHECK_INTERVAL"].flatMap(Int.init) ?? 300
		let composeFile = ProcessInfo.processInfo.environment["COMPOSE_FILE"] ?? "/opt/butteryai/docker-compose.production.yml"
		let composeService = ProcessInfo.processInfo.environment["COMPOSE_SERVICE"] ?? "app"
		let currentVersionOverride = ProcessInfo.processInfo.environment["CURRENT_VERSION"]

		guard !serverBaseURL.isEmpty else {
			logger.error("SERVER_BASE_URL environment variable is required")
			return
		}

		logger.info("Buttery Deployer starting", metadata: [
			"serverBaseURL": .string(serverBaseURL),
			"appName": .string(appName),
			"checkInterval": .stringConvertible(checkInterval),
			"composeFile": .string(composeFile),
		])

		let updateService = AppUpdateService(
			serverBaseURL: serverBaseURL,
			appName: appName,
			currentVersion: currentVersionOverride ?? "0.0.0"
		)

		// Track what we've deployed to avoid re-deploying the same version
		var deployedVersion: String = currentVersionOverride ?? "0.0.0"

		// Handle SIGTERM for graceful shutdown
		let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
		signal(SIGTERM, SIG_IGN)
		signalSource.setEventHandler {
			logger.info("Received SIGTERM, shutting down")
			exit(0)
		}
		signalSource.resume()

		// Main check loop
		while true {
			do {
				let result = try await updateService.checkForUpdates()

				if result.updateAvailable, let dockerImage = result.dockerImage {
					if result.latestVersion != deployedVersion {
						logger.info("New version available", metadata: [
							"current": .string(deployedVersion),
							"latest": .string(result.latestVersion),
							"image": .string(dockerImage),
						])

						let success = await deploy(
							dockerImage: dockerImage,
							composeFile: composeFile,
							composeService: composeService,
							logger: logger
						)

						if success {
							deployedVersion = result.latestVersion
							logger.info("Deployed version \(result.latestVersion)")
						} else {
							logger.error("Deployment failed for version \(result.latestVersion)")
						}
					}
				} else {
					logger.debug("No update available (current: \(deployedVersion))")
				}
			} catch {
				logger.error("Update check failed: \(error.localizedDescription)")
			}

			try? await Task.sleep(for: .seconds(checkInterval))
		}
	}

	static func deploy(
		dockerImage: String,
		composeFile: String,
		composeService: String,
		logger: Logger
	) async -> Bool {
		// Step 1: Pull the new image
		logger.info("Pulling image: \(dockerImage)")
		let pullResult = runProcess("/usr/bin/docker", arguments: ["pull", dockerImage])
		guard pullResult == 0 else {
			logger.error("docker pull failed with exit code \(pullResult)")
			return false
		}

		// Step 2: Restart the compose service with the new image
		logger.info("Restarting compose service: \(composeService)")
		let upResult = runProcess("/usr/bin/docker", arguments: [
			"compose", "-f", composeFile, "up", "-d", "--no-deps", composeService
		])
		guard upResult == 0 else {
			logger.error("docker compose up failed with exit code \(upResult)")
			return false
		}

		// Step 3: Wait for health check
		logger.info("Waiting for health check...")
		try? await Task.sleep(for: .seconds(10))

		let healthResult = runProcess("/usr/bin/docker", arguments: [
			"compose", "-f", composeFile, "ps", "--format", "{{.Status}}", composeService
		])

		return healthResult == 0
	}

	static func runProcess(_ executable: String, arguments: [String]) -> Int32 {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: executable)
		process.arguments = arguments

		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = pipe

		do {
			try process.run()
			process.waitUntilExit()

			if let output = try? pipe.fileHandleForReading.availableData,
			   let text = String(data: output, encoding: .utf8), !text.isEmpty {
				print(text.trimmingCharacters(in: .whitespacesAndNewlines))
			}

			return process.terminationStatus
		} catch {
			print("Failed to run \(executable): \(error)")
			return -1
		}
	}
}
