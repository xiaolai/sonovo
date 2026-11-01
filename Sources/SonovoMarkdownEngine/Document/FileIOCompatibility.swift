// Preserve the existing SonovoCore library API while callers migrate to the
// dependency-free byte I/O module. These aliases introduce no second state.
import SonovoFileIO

public typealias DiskSnapshot = SonovoFileIO.DiskSnapshot
public typealias DiskComparison = SonovoFileIO.DiskComparison
public typealias SaveArtifacts = SonovoFileIO.SaveArtifacts
public typealias SaveMode = SonovoFileIO.SaveMode
public typealias SaveHooks = SonovoFileIO.SaveHooks
public typealias SaveRequest = SonovoFileIO.SaveRequest
public typealias SaveOutcome = SonovoFileIO.SaveOutcome
public typealias SaveError = SonovoFileIO.SaveError
public typealias FileStoreOptions = SonovoFileIO.FileStoreOptions
public typealias SonovoWriteJournal = SonovoFileIO.SonovoWriteJournal
public typealias MarkdownFileWatcher = SonovoFileIO.FileWatcher

package typealias PrivateFileWriter = SonovoFileIO.PrivateFileWriter
