import Foundation
import Testing
@testable import MacSweepCore

struct DockerIDSanitizationTests {
    @Test func containerIDsMustBeHexHashes() {
        let output = """
        aabbccddeeff
        deadbeefcafebabe
        ../etc/passwd
        $(touch pwned)
        not-hex!!
        """
        let ids = DockerModule.sanitizedDockerIDs(from: output, for: .pruneContainers)
        #expect(ids == ["aabbccddeeff", "deadbeefcafebabe"])
    }

    @Test func volumeNamesRejectPathLikeTokens() {
        let output = """
        orphan_volume
        my.volume-1
        /var/lib/docker
        volume;rm
        """
        let names = DockerModule.sanitizedDockerIDs(from: output, for: .pruneVolumes)
        #expect(names == ["orphan_volume", "my.volume-1"])
    }

    @Test func pruneActionsWithoutEnumerationReturnEmpty() {
        #expect(DockerModule.sanitizedDockerIDs(from: "abc", for: .pruneImages).isEmpty)
        #expect(DockerModule.sanitizedDockerIDs(from: "abc", for: .pruneBuildCache).isEmpty)
    }
}
