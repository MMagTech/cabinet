#include "Archive.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <ctype.h>

#include "zlib.h"

extern "C" {
#include "7z.h"
#include "7zAlloc.h"
#include "7zBuf.h"
#include "7zCrc.h"
#include "7zFile.h"
}

// MARK: - .zip

// Hand-rolled rather than pulling in zlib's contrib/minizip: every ROM
// archive this app stages is a single real file plus, at most, directory
// noise (__MACOSX, etc.), never a real multi-member payload, so this only
// needs the two methods every real zip tool actually uses (0 = stored,
// 8 = deflate), read from the central directory's first non-directory,
// non-zero-size entry. Not a general-purpose zip reader.
namespace {

bool zipExtractFirstFile(FILE *f, const char *destDir, char *outFilename, int outFilenameSize) {
    fseek(f, 0, SEEK_END);
    long fileSize = ftell(f);
    // End Of Central Directory record: fixed 22 bytes plus up to 65535
    // bytes of comment, searched backward for its signature since the
    // comment length is the only thing that varies before it.
    long searchStart = fileSize > 65557 ? fileSize - 65557 : 0;
    long searchLen = fileSize - searchStart;
    unsigned char *tail = (unsigned char *)malloc(searchLen);
    if (!tail) return false;
    fseek(f, searchStart, SEEK_SET);
    fread(tail, 1, searchLen, f);

    long eocdOffset = -1;
    for (long i = searchLen - 22; i >= 0; i--) {
        if (tail[i] == 0x50 && tail[i+1] == 0x4b && tail[i+2] == 0x05 && tail[i+3] == 0x06) {
            eocdOffset = i;
            break;
        }
    }
    if (eocdOffset < 0) { free(tail); return false; }

    unsigned short entryCount = tail[eocdOffset+10] | (tail[eocdOffset+11] << 8);
    unsigned int cdOffset = tail[eocdOffset+16] | (tail[eocdOffset+17] << 8)
        | (tail[eocdOffset+18] << 16) | (tail[eocdOffset+19] << 24);
    free(tail);
    if (entryCount == 0) return false;

    fseek(f, cdOffset, SEEK_SET);
    for (unsigned short i = 0; i < entryCount; i++) {
        unsigned char hdr[46];
        if (fread(hdr, 1, 46, f) != 46) return false;
        if (hdr[0] != 0x50 || hdr[1] != 0x4b || hdr[2] != 0x01 || hdr[3] != 0x02) return false;

        unsigned short method = hdr[10] | (hdr[11] << 8);
        unsigned int compSize = hdr[20] | (hdr[21] << 8) | (hdr[22] << 16) | (hdr[23] << 24);
        unsigned int uncompSize = hdr[24] | (hdr[25] << 8) | (hdr[26] << 16) | (hdr[27] << 24);
        unsigned short nameLen = hdr[28] | (hdr[29] << 8);
        unsigned short extraLen = hdr[30] | (hdr[31] << 8);
        unsigned short commentLen = hdr[32] | (hdr[33] << 8);
        unsigned int localOffset = hdr[42] | (hdr[43] << 8) | (hdr[44] << 16) | (hdr[45] << 24);

        char nameBuf[1024];
        size_t nameToRead = nameLen < sizeof(nameBuf) - 1 ? nameLen : sizeof(nameBuf) - 1;
        if (fread(nameBuf, 1, nameToRead, f) != nameToRead) return false;
        nameBuf[nameToRead] = '\0';
        if (nameLen > nameToRead) fseek(f, nameLen - nameToRead, SEEK_CUR);

        long nextEntry = ftell(f) + extraLen + commentLen;
        // A directory entry ends its name with '/' and carries no bytes;
        // real ROM content never does either.
        bool looksLikeFile = uncompSize > 0 && (nameToRead == 0 || nameBuf[nameToRead - 1] != '/');
        if (!looksLikeFile) {
            fseek(f, nextEntry, SEEK_SET);
            continue;
        }

        // Found the entry: read its local header to get the real data
        // offset (the local header's own name/extra lengths can differ
        // in padding from the central directory's).
        unsigned char lhdr[30];
        fseek(f, localOffset, SEEK_SET);
        if (fread(lhdr, 1, 30, f) != 30) return false;
        if (lhdr[0] != 0x50 || lhdr[1] != 0x4b || lhdr[2] != 0x03 || lhdr[3] != 0x04) return false;
        unsigned short localNameLen = lhdr[26] | (lhdr[27] << 8);
        unsigned short localExtraLen = lhdr[28] | (lhdr[29] << 8);
        long dataOffset = localOffset + 30 + localNameLen + localExtraLen;

        // The entry's own name may carry a path (folder-in-zip); only
        // the base filename is meaningful once staged flat.
        const char *base = strrchr(nameBuf, '/');
        base = base ? base + 1 : nameBuf;
        snprintf(outFilename, outFilenameSize, "%s", base);
        char destPath[2048];
        snprintf(destPath, sizeof(destPath), "%s/%s", destDir, outFilename);

        FILE *out = fopen(destPath, "wb");
        if (!out) return false;
        fseek(f, dataOffset, SEEK_SET);

        bool ok = true;
        if (method == 0) {
            unsigned char buf[65536];
            unsigned int remaining = compSize;
            while (remaining > 0) {
                size_t chunk = remaining < sizeof(buf) ? remaining : sizeof(buf);
                if (fread(buf, 1, chunk, f) != chunk) { ok = false; break; }
                fwrite(buf, 1, chunk, out);
                remaining -= (unsigned int)chunk;
            }
        } else if (method == 8) {
            z_stream strm = {};
            // -15: raw deflate, no zlib header, matching what zip stores.
            if (inflateInit2(&strm, -15) != Z_OK) { ok = false; }
            else {
                unsigned char inBuf[65536], outBuf[65536];
                unsigned int remaining = compSize;
                int zret = Z_OK;
                while (ok && remaining > 0 && zret != Z_STREAM_END) {
                    size_t chunk = remaining < sizeof(inBuf) ? remaining : sizeof(inBuf);
                    if (fread(inBuf, 1, chunk, f) != chunk) { ok = false; break; }
                    remaining -= (unsigned int)chunk;
                    strm.next_in = inBuf;
                    strm.avail_in = (uInt)chunk;
                    do {
                        strm.next_out = outBuf;
                        strm.avail_out = sizeof(outBuf);
                        zret = inflate(&strm, Z_NO_FLUSH);
                        if (zret != Z_OK && zret != Z_STREAM_END) { ok = false; break; }
                        fwrite(outBuf, 1, sizeof(outBuf) - strm.avail_out, out);
                    } while (strm.avail_out == 0);
                }
                inflateEnd(&strm);
            }
        } else {
            ok = false; // an unsupported method (e.g. bzip2/LZMA-in-zip): rare for ROMs
        }
        fclose(out);
        return ok;
    }
    return false;
}

// MARK: - .7z

bool sevenZipExtractFirstFile(const char *archivePath, const char *destDir,
                               char *outFilename, int outFilenameSize) {
    CFileInStream archiveStream;
    CLookToRead2 lookStream;
    CSzArEx db;
    ISzAlloc allocImp = { SzAlloc, SzFree };
    ISzAlloc allocTempImp = { SzAlloc, SzFree };
    SRes res;

    if (InFile_Open(&archiveStream.file, archivePath) != 0) return false;
    FileInStream_CreateVTable(&archiveStream);
    LookToRead2_CreateVTable(&lookStream, False);
    lookStream.buf = (Byte *)ISzAlloc_Alloc(&allocImp, 1 << 18);
    if (!lookStream.buf) { File_Close(&archiveStream.file); return false; }
    lookStream.bufSize = 1 << 18;
    lookStream.realStream = &archiveStream.vt;
    LookToRead2_INIT(&lookStream);

    CrcGenerateTable();
    SzArEx_Init(&db);
    res = SzArEx_Open(&db, &lookStream.vt, &allocImp, &allocTempImp);

    bool wroteFile = false;
    if (res == SZ_OK) {
        UInt32 blockIndex = 0xFFFFFFFF;
        Byte *outBuffer = nullptr;
        size_t outBufferSize = 0;
        UInt16 nameBuf16[1024];
        for (UInt32 i = 0; i < db.NumFiles && !wroteFile; i++) {
            if (SzArEx_IsDir(&db, i)) continue;
            if (SzArEx_GetFileSize(&db, i) == 0) continue;

            size_t offset = 0, outSizeProcessed = 0;
            res = SzArEx_Extract(&db, &lookStream.vt, i, &blockIndex, &outBuffer, &outBufferSize,
                                  &offset, &outSizeProcessed, &allocImp, &allocTempImp);
            if (res != SZ_OK) break;

            // ROM filenames inside 7z archives are effectively always
            // ASCII; a plain truncating UTF16->char copy is enough here,
            // this only feeds a staged file's name, never displayed.
            size_t nameLen16 = SzArEx_GetFileNameUtf16(&db, i, nameBuf16);
            char nameBuf[1024];
            size_t j = 0;
            for (; j < nameLen16 && j < sizeof(nameBuf) - 1 && nameBuf16[j] != 0; j++) {
                nameBuf[j] = (char)(nameBuf16[j] < 128 ? nameBuf16[j] : '_');
            }
            nameBuf[j] = '\0';
            const char *base = strrchr(nameBuf, '\\');
            if (!base) base = strrchr(nameBuf, '/');
            base = base ? base + 1 : nameBuf;
            snprintf(outFilename, outFilenameSize, "%s", base);

            char destPath[2048];
            snprintf(destPath, sizeof(destPath), "%s/%s", destDir, outFilename);
            FILE *out = fopen(destPath, "wb");
            if (out) {
                fwrite(outBuffer + offset, 1, outSizeProcessed, out);
                fclose(out);
                wroteFile = true;
            }
        }
        if (outBuffer) ISzAlloc_Free(&allocImp, outBuffer);
    }

    SzArEx_Free(&db, &allocImp);
    ISzAlloc_Free(&allocImp, lookStream.buf);
    File_Close(&archiveStream.file);
    return wroteFile;
}

bool hasSuffix(const char *s, const char *suffix) {
    size_t sLen = strlen(s), sufLen = strlen(suffix);
    if (sufLen > sLen) return false;
    for (size_t i = 0; i < sufLen; i++) {
        if (tolower(s[sLen - sufLen + i]) != tolower(suffix[i])) return false;
    }
    return true;
}

} // namespace

int archive_extract_first_file(const char *archivePath, const char *destDir,
                                char *outFilename, int outFilenameSize) {
    if (hasSuffix(archivePath, ".zip")) {
        FILE *f = fopen(archivePath, "rb");
        if (!f) return 0;
        bool ok = zipExtractFirstFile(f, destDir, outFilename, outFilenameSize);
        fclose(f);
        return ok ? 1 : 0;
    }
    if (hasSuffix(archivePath, ".7z")) {
        return sevenZipExtractFirstFile(archivePath, destDir, outFilename, outFilenameSize) ? 1 : 0;
    }
    return 0;
}
