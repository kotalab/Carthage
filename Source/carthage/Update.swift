import CarthageKit
import Commandant
import Foundation
import Result
import ReactiveSwift
import Curry

/// Type that encapsulates the configuration and evaluation of the `update` subcommand.
public struct UpdateCommand: CommandProtocol {
	public struct Options: OptionsProtocol {
		public let checkoutAfterUpdate: Bool = true
		public let buildAfterUpdate: Bool = true
		public let isVerbose: Bool = false
		public let logPath: String?
		public let useNewResolver: Bool
		public let buildOptions: CarthageKit.BuildOptions
		public let checkoutOptions: CheckoutCommand.Options
		public let dependenciesToUpdate: [String]?

		/// The build options corresponding to these options.
		public var buildCommandOptions: BuildCommand.Options {
			return BuildCommand.Options(
				buildOptions: buildOptions,
				skipCurrent: true,
				colorOptions: checkoutOptions.colorOptions,
				isVerbose: isVerbose,
				directoryPath: checkoutOptions.directoryPath,
				logPath: logPath,
				archive: false,
				dependenciesToBuild: dependenciesToUpdate
			)
		}

		/// If `checkoutAfterUpdate` and `buildAfterUpdate` are both true, this will
		/// be a producer representing the work necessary to build the project.
		///
		/// Otherwise, this producer will be empty.
		public var buildProducer: SignalProducer<(), CarthageError> {
			if checkoutAfterUpdate && buildAfterUpdate {
				return BuildCommand().buildWithOptions(buildCommandOptions)
			} else {
				return .empty
			}
		}

		private init(logPath: String?,
		             useNewResolver: Bool,
		             buildOptions: BuildOptions,
		             checkoutOptions: CheckoutCommand.Options
		) {
			self.logPath = logPath
			self.useNewResolver = useNewResolver
			self.buildOptions = buildOptions
			self.checkoutOptions = checkoutOptions
			self.dependenciesToUpdate = checkoutOptions.dependenciesToCheckout
		}

		public static func evaluate(_ mode: CommandMode) -> Result<Options, CommandantError<CarthageError>> {
			let buildDescription = "skip the building of dependencies after updating\n(ignored if --no-checkout option is present)"

			let dependenciesUsage = "the dependency names to update, checkout and build"

			return curry(Options.init)
				<*> mode <| Option(key: "log-path", defaultValue: nil, usage: "path to the xcode build output. A temporary file is used by default")
				<*> mode <| Option(key: "new-resolver", defaultValue: false, usage: "use the new resolver codeline when calculating dependencies. Default is false")
				<*> BuildOptions.evaluate(mode, addendum: "\n(ignored if --no-build option is present)")
				<*> CheckoutCommand.Options.evaluate(mode, dependenciesUsage: dependenciesUsage)
		}

		/// Attempts to load the project referenced by the options, and configure it
		/// accordingly.
		public func loadProject() -> SignalProducer<Project, CarthageError> {
			return checkoutOptions.loadProject()
		}
	}

	public let verb = "update"
	public let function = "Update and rebuild the project's dependencies"

	public func run(_ options: Options) -> Result<(), CarthageError> {
		return options.loadProject()
			.flatMap(.merge) { project -> SignalProducer<(), CarthageError> in

				let checkDependencies: SignalProducer<(), CarthageError>
				if let depsToUpdate = options.dependenciesToUpdate {
					checkDependencies = project
						.loadCombinedCartfile()
						.flatMap(.concat) { cartfile -> SignalProducer<(), CarthageError> in
							let dependencyNames = cartfile.dependencies.keys.map { $0.name.lowercased() }
							let unknownDependencyNames = Set(depsToUpdate.map { $0.lowercased() }).subtracting(dependencyNames)

							if !unknownDependencyNames.isEmpty {
								return SignalProducer(error: .unknownDependencies(unknownDependencyNames.sorted()))
							}
							return .empty
						}
				} else {
					checkDependencies = .empty
				}

				let updateDependencies = project.updateDependencies(
					shouldCheckout: options.checkoutAfterUpdate, useNewResolver: options.useNewResolver, buildOptions: options.buildOptions,
					dependenciesToUpdate: options.dependenciesToUpdate
				)

				return checkDependencies.then(updateDependencies)
			}
			.then(options.buildProducer)
			.waitOnCommand()
	}
}
