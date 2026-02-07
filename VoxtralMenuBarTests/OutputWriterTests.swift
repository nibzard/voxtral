import XCTest
@testable import VoxtralMenuBar

final class OutputWriterTests: XCTestCase {

    // MARK: - Temporary Directory Setup

    private var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        let tempDir = FileManager.default.temporaryDirectory
        tempDirectory = tempDir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        try await super.tearDown()
    }

    // MARK: - Filename Generation Tests

    func testFileNameFormat() throws {
        let testDate = Date(timeIntervalSince1970: 0) // 1970-01-01 00:00:00 UTC
        let fileName = OutputWriter.fileName(for: testDate)

        // Format should be YYYY-MM-DD_HHMMSS_transcript.md
        // The exact format depends on timezone, so we check pattern
        XCTAssertTrue(fileName.hasSuffix("_transcript.md"), "Filename should end with '_transcript.md'")
        XCTAssertFalse(fileName.contains("/"), "Filename should not contain path separators")
        XCTAssertFalse(fileName.contains("\\"), "Filename should not contain path separators")
    }

    func testFileNameIsDeterministic() throws {
        let testDate = Date()
        let fileName1 = OutputWriter.fileName(for: testDate)
        let fileName2 = OutputWriter.fileName(for: testDate)

        XCTAssertEqual(fileName1, fileName2, "Same date should produce same filename")
    }

    func testFileNameChangesWithTime() throws {
        let date1 = Date(timeIntervalSince1970: 0)
        let date2 = Date(timeIntervalSince1970: 3600) // 1 hour later

        let fileName1 = OutputWriter.fileName(for: date1)
        let fileName2 = OutputWriter.fileName(for: date2)

        XCTAssertNotEqual(fileName1, fileName2, "Different dates should produce different filenames")
    }

    func testFileNameUniquenessWithCollisions() throws {
        let testDate = Date()

        // First file should use base name
        let url1 = OutputWriter.uniqueFileURL(in: tempDirectory, for: testDate)
        XCTAssertTrue(url1.lastPathComponent.contains("_transcript.md"), "Should contain transcript suffix")
        XCTAssertFalse(url1.lastPathComponent.contains("_1_transcript.md"), "First file should not have counter")
        XCTAssertFalse(url1.lastPathComponent.contains("_2_transcript.md"), "First file should not have counter")

        // Create the first file
        try Data().write(to: url1)

        // Second file with same date should get suffix
        let url2 = OutputWriter.uniqueFileURL(in: tempDirectory, for: testDate)
        XCTAssertTrue(url2.lastPathComponent.contains("_1_transcript.md"), "Second file should have _1 suffix")
        XCTAssertNotEqual(url1.lastPathComponent, url2.lastPathComponent, "Filenames should be different")

        // Create the second file
        try Data().write(to: url2)

        // Third file should get _2 suffix
        let url3 = OutputWriter.uniqueFileURL(in: tempDirectory, for: testDate)
        XCTAssertTrue(url3.lastPathComponent.contains("_2_transcript.md"), "Third file should have _2 suffix")
        XCTAssertNotEqual(url1.lastPathComponent, url3.lastPathComponent, "Third filename should differ from first")
        XCTAssertNotEqual(url2.lastPathComponent, url3.lastPathComponent, "Third filename should differ from second")
    }

    func testFileNameUniquenessAcrossDifferentDates() throws {
        let date1 = Date(timeIntervalSince1970: 0)
        let date2 = Date(timeIntervalSince1970: 3600) // 1 hour later

        let url1 = OutputWriter.uniqueFileURL(in: tempDirectory, for: date1)
        let url2 = OutputWriter.uniqueFileURL(in: tempDirectory, for: date2)

        // Different dates should produce different filenames even without existing files
        XCTAssertNotEqual(url1.lastPathComponent, url2.lastPathComponent, "Different dates should produce different filenames")
    }

    func testUniqueFileURLIsUniqueWithoutExistingFiles() throws {
        let testDate = Date(timeIntervalSince1970: 0)

        let url1 = OutputWriter.uniqueFileURL(in: tempDirectory, for: testDate)
        let url2 = OutputWriter.uniqueFileURL(in: tempDirectory, for: testDate)

        XCTAssertNotEqual(url1.lastPathComponent, url2.lastPathComponent, "Unique URLs should differ even before files exist")
        XCTAssertFalse(url1.lastPathComponent.contains("_1_transcript.md"), "First URL should not have counter suffix")
        XCTAssertTrue(url2.lastPathComponent.contains("_1_transcript.md"), "Second URL should have _1 counter suffix")
    }

    func testOutputWriterCreatesUniqueFileWhenCollisionOccurs() throws {
        let testDate = Date()

        // Create first writer with the same date
        let writer1 = try OutputWriter(outputDirectory: tempDirectory, date: testDate)
        let file1Name = writer1.fileURL.lastPathComponent

        // Verify first file has base name (no counter)
        let hasCounter = file1Name.contains("_1_transcript.md") || file1Name.contains("_2_transcript.md")
        XCTAssertFalse(hasCounter, "First file should not have counter suffix")

        writer1.finish()
        Thread.sleep(forTimeInterval: 0.1)

        // Create second writer with the same date
        let writer2 = try OutputWriter(outputDirectory: tempDirectory, date: testDate)
        let file2Name = writer2.fileURL.lastPathComponent

        // Verify second file has counter suffix
        XCTAssertTrue(file2Name.contains("_1_transcript.md"), "Second file should have _1 counter suffix")

        // Verify files are different
        XCTAssertNotEqual(writer1.fileURL.path, writer2.fileURL.path, "File paths should be unique")

        // Verify both files exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: writer1.fileURL.path), "First file should exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: writer2.fileURL.path), "Second file should exist")

        writer2.finish()
    }

    // MARK: - Header Metadata Tests

    func testHeaderContainsRequiredFields() throws {
        let config = OutputWriter.Configuration(
            modelName: "TestModel",
            appName: "TestApp",
            appVersion: "1.0.0",
            deviceDescription: "TestDevice"
        )

        let testDate = Date(timeIntervalSince1970: 0)
        let header = OutputWriter.header(for: testDate, configuration: config)

        XCTAssertTrue(header.contains("# Transcript -"), "Header should start with '# Transcript -'")
        XCTAssertTrue(header.contains("- Device: TestDevice"), "Header should contain device description")
        XCTAssertTrue(header.contains("- Model: TestModel"), "Header should contain model name")
        XCTAssertTrue(header.contains("- App: TestApp 1.0.0"), "Header should contain app name and version")
    }

    func testHeaderEndsWithNewlines() throws {
        let config = OutputWriter.Configuration()
        let testDate = Date()
        let header = OutputWriter.header(for: testDate, configuration: config)

        XCTAssertTrue(header.hasSuffix("\n\n"), "Header should end with two newlines")
    }

    // MARK: - Timestamp Formatting Tests

    func testTimestampFormatting() {
        XCTAssertEqual(OutputWriter.formatTimestamp(0), "00:00.000", "Zero ms should format as 00:00.000")
        XCTAssertEqual(OutputWriter.formatTimestamp(1000), "00:01.000", "1000 ms should format as 00:01.000")
        XCTAssertEqual(OutputWriter.formatTimestamp(61000), "01:01.000", "61000 ms should format as 01:01.000")
        XCTAssertEqual(OutputWriter.formatTimestamp(3661000), "61:01.000", "3661000 ms should format as 61:01.000")
        XCTAssertEqual(OutputWriter.formatTimestamp(123), "00:00.123", "123 ms should format as 00:00.123")
        XCTAssertEqual(OutputWriter.formatTimestamp(500), "00:00.500", "500 ms should format as 00:00.500")
    }

    func testNegativeTimestampFormatting() {
        // Negative values should be clamped to zero
        XCTAssertEqual(OutputWriter.formatTimestamp(-100), "00:00.000", "Negative ms should format as 00:00.000")
    }

    // MARK: - Text Sanitization Tests

    func testSanitizeRemovesNewlines() {
        let input = "line1\nline2\rline3\r\nline4"
        let sanitized = OutputWriter.sanitize(input)
        XCTAssertEqual(sanitized, "line1 line2 line3 line4", "All newline variants should be replaced with spaces")
    }

    func testSanitizeTrimsWhitespace() {
        XCTAssertEqual(OutputWriter.sanitize("  text  "), "text", "Leading/trailing whitespace should be trimmed")
        XCTAssertEqual(OutputWriter.sanitize("\n\n  text  \n\n"), "text", "Whitespace around newlines should be cleaned")
    }

    func testSanitizeEmptyAfterTrimming() {
        XCTAssertEqual(OutputWriter.sanitize(""), "", "Empty string should stay empty")
        XCTAssertEqual(OutputWriter.sanitize("   \n\n  "), "", "Whitespace-only string should become empty")
        XCTAssertEqual(OutputWriter.sanitize("\n\n"), "", "Newline-only string should become empty")
    }

    func testSanitizePreservesInternalSpaces() {
        XCTAssertEqual(OutputWriter.sanitize("hello world"), "hello world", "Internal spaces should be preserved")
        XCTAssertEqual(OutputWriter.sanitize("  hello   world  "), "hello   world", "Multiple internal spaces preserved after trim")
    }

    // MARK: - File Creation Tests

    func testCreatesFileWithHeader() throws {
        let config = OutputWriter.Configuration(
            modelName: "TestModel",
            appName: "TestApp",
            appVersion: "1.0.0",
            deviceDescription: "TestDevice"
        )

        let writer = try OutputWriter(outputDirectory: tempDirectory, configuration: config)
        XCTAssertTrue(FileManager.default.fileExists(atPath: writer.fileURL.path), "File should be created")

        let contents = try String(contentsOf: writer.fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("# Transcript -"), "File should contain header")
        XCTAssertTrue(contents.contains("TestModel"), "File should contain model name")
    }

    func testFileCreationFailsForNonExistentDirectory() {
        let nonExistentDir = tempDirectory.appendingPathComponent("does/not/exist")

        XCTAssertThrowsError(try OutputWriter(outputDirectory: nonExistentDir)) { error in
            XCTAssertTrue(error is OutputWriter.OutputWriterError, "Should throw OutputWriterError")
        }
    }

    func testFileCreationFailsForFileURL() throws {
        // Create a file instead of a directory
        let fileURL = tempDirectory.appendingPathComponent("not_a_dir")
        try Data().write(to: fileURL)

        XCTAssertThrowsError(try OutputWriter(outputDirectory: fileURL)) { error in
            XCTAssertTrue(error is OutputWriter.OutputWriterError, "Should throw OutputWriterError")
        }
    }

    // MARK: - Line Appending Tests

    func testAppendLineWritesToFile() throws {
        let writer = try OutputWriter(outputDirectory: tempDirectory)

        writer.appendLine(timestampMs: 1234, text: "Test transcript line")

        // Wait for async write
        Thread.sleep(forTimeInterval: 0.1)

        let contents = try String(contentsOf: writer.fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("[00:01.234] Test transcript line"), "File should contain timestamped line")
    }

    func testAppendLineSkipsEmptyText() throws {
        let writer = try OutputWriter(outputDirectory: tempDirectory)

        writer.appendLine(timestampMs: 1000, text: "")

        Thread.sleep(forTimeInterval: 0.1)

        let contentsBefore = try String(contentsOf: writer.fileURL, encoding: .utf8)

        writer.appendLine(timestampMs: 2000, text: "   ")

        Thread.sleep(forTimeInterval: 0.1)

        let contentsAfter = try String(contentsOf: writer.fileURL, encoding: .utf8)
        XCTAssertEqual(contentsBefore, contentsAfter, "Whitespace-only text should not be written")
    }

    func testAppendRawLineWritesContent() throws {
        let writer = try OutputWriter(outputDirectory: tempDirectory)

        writer.appendRawLine("Raw line without formatting")

        Thread.sleep(forTimeInterval: 0.1)

        let contents = try String(contentsOf: writer.fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("Raw line without formatting"), "File should contain raw line")
    }

    func testAppendRawLineAddsNewlineIfNeeded() throws {
        let writer = try OutputWriter(outputDirectory: tempDirectory)

        writer.appendRawLine("Line 1")
        writer.appendRawLine("Line 2")

        Thread.sleep(forTimeInterval: 0.1)

        let contents = try String(contentsOf: writer.fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("Line 1\n"), "Should add newline if missing")
        XCTAssertTrue(contents.contains("Line 2\n"), "Should add newline if missing")
    }

    // MARK: - TranscriptMessage Tests

    func testAppendTranscriptWithFinalMessage() throws {
        let writer = try OutputWriter(outputDirectory: tempDirectory)

        let message = TranscriptionClient.TranscriptMessage(
            seq: 1,
            startMs: 5000,
            endMs: 6000,
            text: "Final transcript text",
            isFinal: true,
            confidence: nil
        )

        writer.appendTranscript(message)

        Thread.sleep(forTimeInterval: 0.1)

        let contents = try String(contentsOf: writer.fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("[00:05.000] Final transcript text"), "Should write final message")
    }

    func testAppendTranscriptSkipsPartialByDefault() throws {
        let writer = try OutputWriter(outputDirectory: tempDirectory)

        let partialMessage = TranscriptionClient.TranscriptMessage(
            seq: 1,
            startMs: 1000,
            endMs: 1500,
            text: "Partial text",
            isFinal: false,
            confidence: nil
        )

        writer.appendTranscript(partialMessage)

        Thread.sleep(forTimeInterval: 0.1)

        let contents = try String(contentsOf: writer.fileURL, encoding: .utf8)
        let lines = contents.components(separatedBy: .newlines)
        let transcriptLines = lines.filter { $0.contains("]") }

        // Should only have header lines (no transcript lines with timestamps)
        XCTAssertEqual(transcriptLines.count, 0, "Partial message should not be written")
    }

    func testAppendTranscriptIncludesPartialWhenRequested() throws {
        let writer = try OutputWriter(outputDirectory: tempDirectory)

        let partialMessage = TranscriptionClient.TranscriptMessage(
            seq: 1,
            startMs: 1000,
            endMs: 1500,
            text: "Partial text",
            isFinal: false,
            confidence: nil
        )

        writer.appendTranscript(partialMessage, includePartial: true)

        Thread.sleep(forTimeInterval: 0.1)

        let contents = try String(contentsOf: writer.fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("[00:01.000] Partial text"), "Should write partial when includePartial is true")
    }

    // MARK: - Finish Tests

    func testFinishClosesFile() throws {
        let writer = try OutputWriter(outputDirectory: tempDirectory)
        let fileURL = writer.fileURL

        writer.appendLine(timestampMs: 1000, text: "Before finish")

        // Call finish and wait
        writer.finish()
        Thread.sleep(forTimeInterval: 0.2)

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("Before finish"), "Content before finish should be present")

        // Try to write after finish (should be ignored silently)
        writer.appendLine(timestampMs: 2000, text: "After finish")
        Thread.sleep(forTimeInterval: 0.1)

        let contentsAfter = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(contentsAfter.contains("After finish"), "Writes after finish should be ignored")
    }

    // MARK: - Integration Tests

    func testFullTranscriptWorkflow() throws {
        let config = OutputWriter.Configuration(
            modelName: "Voxtral-Test-Model",
            appName: "Voxtral Test",
            appVersion: "0.1.0",
            deviceDescription: "MacBook Pro (Apple Silicon)"
        )

        let writer = try OutputWriter(outputDirectory: tempDirectory, configuration: config)

        // Simulate a transcript session
        let messages = [
            TranscriptionClient.TranscriptMessage(seq: 1, startMs: 0, endMs: 500, text: "Hello", isFinal: true, confidence: nil),
            TranscriptionClient.TranscriptMessage(seq: 2, startMs: 500, endMs: 1500, text: "world", isFinal: true, confidence: nil),
            TranscriptionClient.TranscriptMessage(seq: 3, startMs: 1500, endMs: 2500, text: "this is a test", isFinal: true, confidence: nil),
        ]

        for message in messages {
            writer.appendTranscript(message)
        }

        writer.finish()
        Thread.sleep(forTimeInterval: 0.2)

        let contents = try String(contentsOf: writer.fileURL, encoding: .utf8)

        // Verify header
        XCTAssertTrue(contents.contains("# Transcript -"), "Should have header title")
        XCTAssertTrue(contents.contains("Voxtral-Test-Model"), "Should have model name")
        XCTAssertTrue(contents.contains("Voxtral Test 0.1.0"), "Should have app info")

        // Verify transcript lines
        XCTAssertTrue(contents.contains("[00:00.000] Hello"), "Should have first line")
        XCTAssertTrue(contents.contains("[00:00.500] world"), "Should have second line")
        XCTAssertTrue(contents.contains("[00:01.500] this is a test"), "Should have third line")
    }

    func testMultipleWritersSameDirectory() throws {
        let writer1 = try OutputWriter(outputDirectory: tempDirectory)
        let writer2 = try OutputWriter(outputDirectory: tempDirectory)

        XCTAssertNotEqual(writer1.fileURL, writer2.fileURL, "Each writer should create a unique file")

        writer1.appendLine(timestampMs: 1000, text: "Writer 1")
        writer2.appendLine(timestampMs: 2000, text: "Writer 2")

        writer1.finish()
        writer2.finish()

        Thread.sleep(forTimeInterval: 0.2)

        let contents1 = try String(contentsOf: writer1.fileURL, encoding: .utf8)
        let contents2 = try String(contentsOf: writer2.fileURL, encoding: .utf8)

        XCTAssertTrue(contents1.contains("Writer 1"), "Writer 1 should have its content")
        XCTAssertTrue(contents2.contains("Writer 2"), "Writer 2 should have its content")
        XCTAssertFalse(contents1.contains("Writer 2"), "Writer 1 should not have Writer 2's content")
    }

    // MARK: - Configuration Tests

    func testConfigurationDefaultValues() {
        let config = OutputWriter.Configuration()

        XCTAssertFalse(config.modelName.isEmpty, "Default model name should not be empty")
        XCTAssertFalse(config.appName.isEmpty, "Default app name should not be empty")
        XCTAssertFalse(config.appVersion.isEmpty, "Default app version should not be empty")
        XCTAssertFalse(config.deviceDescription.isEmpty, "Default device description should not be empty")
    }

    func testConfigurationCustomValues() {
        let config = OutputWriter.Configuration(
            modelName: "CustomModel",
            appName: "CustomApp",
            appVersion: "2.0.0",
            deviceDescription: "CustomDevice"
        )

        XCTAssertEqual(config.modelName, "CustomModel")
        XCTAssertEqual(config.appName, "CustomApp")
        XCTAssertEqual(config.appVersion, "2.0.0")
        XCTAssertEqual(config.deviceDescription, "CustomDevice")
    }
}
