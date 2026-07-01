import Foundation

/// Writes changes to a `database V2` file's bytes.
///
/// Rewriting is done surgically at the chunk level rather than by fully
/// re-serializing a parsed `[Track]` model: every `otrk` record that isn't
/// being changed is copied through byte-for-byte, including any fields this
/// codebase doesn't parse into `Track`. Round-tripping through a model
/// would silently drop fields Serato understands but we don't yet model —
/// unacceptable for a file a bug could corrupt in a real user's library.
public enum SeratoDatabaseWriter {
    /// Rewrites the `pfil` field of every `otrk` record whose current
    /// decoded path equals `oldPath`, replacing it with `newPath`. Returns
    /// the new file contents and whether any record was actually changed.
    public static func rewritingPath(
        _ oldPath: String,
        to newPath: String,
        in fileData: Data
    ) -> (data: Data, didRewrite: Bool) {
        var didRewrite = false
        let topLevel = SeratoChunkCodec.readChunks(from: fileData)

        let newChunks: [SeratoChunk] = topLevel.map { chunk in
            guard chunk.tag == "otrk" else { return chunk }
            let fields = SeratoChunkCodec.readChunks(from: chunk.payload)
            guard
                let pfilField = fields.first(where: { $0.tag == "pfil" }),
                SeratoChunkCodec.decodeUTF16BEString(pfilField.payload) == oldPath
            else {
                return chunk
            }

            didRewrite = true
            let newFields = fields.map { field -> SeratoChunk in
                guard field.tag == "pfil" else { return field }
                return SeratoChunk(tag: "pfil", payload: SeratoChunkCodec.encodeUTF16BEString(newPath))
            }
            return SeratoChunk(tag: "otrk", payload: SeratoChunkCodec.writeChunks(newFields))
        }

        return (SeratoChunkCodec.writeChunks(newChunks), didRewrite)
    }
}
