#ifndef Archive_h
#define Archive_h

#ifdef __cplusplus
extern "C" {
#endif

/// Extracts the first (only, in every real ROM archive this app ever
/// stages) non-directory entry from a .zip or .7z archive into destDir,
/// under the archive entry's own real filename, not the archive's. Some
/// cores fall back to sniffing the file extension when richer metadata
/// isn't available (this frontend does not yet answer
/// RETRO_ENVIRONMENT_GET_GAME_INFO_EXT), so a renamed or extension-less
/// staged file can mislead a core that would have identified the ROM
/// correctly from its real name.
///
/// Every cartridge-style native core expects a raw ROM file, either via a
/// path it opens itself or bytes this app reads and hands over directly;
/// none of them decompress archives on their own the way FBNeo's own
/// arcade-set loader does, so this exists to bridge that gap before a ROM
/// ever reaches a core. Archive format is picked by the archive's own
/// file extension, not content sniffing: RomM's own filenames are
/// already honest about what they are.
///
/// outFilename receives the extracted file's real name (not a full
/// path), truncated to fit outFilenameSize. Returns true on success.
int archive_extract_first_file(const char *archivePath, const char *destDir,
                                char *outFilename, int outFilenameSize);

#ifdef __cplusplus
}
#endif

#endif /* Archive_h */
