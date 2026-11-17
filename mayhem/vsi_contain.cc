// Linked into gdal_algorithm_fuzzer only. That harness runs whatever algorithm and arguments the input
// names (`gdal vsi delete -r`, `--output <path>`, `/vsistdin/` ...), so before main() this makes the
// process's real filesystem read-only to GDAL and removes /vsistdin/ and /vsistdout/. Everything an
// input can write lives under /vsimem/, which the harness empties after each input.
#include <cerrno>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <memory>
#include <sys/stat.h>
#include <type_traits>
#include <unistd.h>

#include "cpl_string.h"
#include "cpl_vsi.h"
#include "cpl_vsi_virtual.h"

static_assert(std::is_same_v<VSIStatBufL, struct stat64>, "VSIStatBufL is struct stat64 on Linux");

namespace
{
class RegularFileReadHandle final : public VSIVirtualHandle
{
    int m_fd;
    vsi_l_offset m_pos = 0;
    bool m_eof = false;

  public:
    explicit RegularFileReadHandle(int fd) : m_fd(fd)
    {
    }

    using VSIVirtualHandle::Read;
    using VSIVirtualHandle::Seek;
    using VSIVirtualHandle::Write;

    int Seek(vsi_l_offset nOffset, int nWhence) override
    {
        m_eof = false;
        if (nWhence == SEEK_SET)
        {
            m_pos = nOffset;
        }
        else if (nWhence == SEEK_CUR)
        {
            m_pos += nOffset;
        }
        else
        {
            struct stat64 sStat;
            if (fstat64(m_fd, &sStat) != 0)
                return -1;
            m_pos = static_cast<vsi_l_offset>(sStat.st_size) + nOffset;
        }
        return 0;
    }

    vsi_l_offset Tell() override
    {
        return m_pos;
    }

    size_t Read(void *pBuffer, size_t nBytes) override
    {
        size_t nTotal = 0;
        while (nTotal < nBytes)
        {
            const ssize_t nRead = pread64(m_fd, static_cast<char *>(pBuffer) + nTotal, nBytes - nTotal,
                                          static_cast<off64_t>(m_pos));
            if (nRead <= 0)
            {
                m_eof = (nRead == 0);
                break;
            }
            nTotal += static_cast<size_t>(nRead);
            m_pos += static_cast<vsi_l_offset>(nRead);
        }
        return nTotal;
    }

    size_t Write(const void *, size_t) override
    {
        errno = EBADF;
        return 0;
    }

    void ClearErr() override
    {
        m_eof = false;
    }

    int Eof() override
    {
        return m_eof;
    }

    int Error() override
    {
        return 0;
    }

    int Close() override
    {
        const int nRet = close(m_fd);
        m_fd = -1;
        return nRet;
    }

    ~RegularFileReadHandle() override
    {
        if (m_fd >= 0)
            close(m_fd);
    }
};

// Replaces GDAL's default (real filesystem) handler: regular files can be read and directories listed,
// nothing can be created, written, renamed or removed (the base class returns -1 for those).
class ReadOnlyRealFilesystem final : public VSIFilesystemHandler
{
  public:
    VSIVirtualHandleUniquePtr Open(const char *pszFilename, const char *pszAccess, bool, CSLConstList) override
    {
        if (!pszAccess || pszAccess[0] != 'r' || strchr(pszAccess, '+'))
        {
            errno = EACCES;
            return nullptr;
        }
        // O_NONBLOCK so that opening a FIFO or device returns at once; only regular files are kept.
        const int fd = open(pszFilename, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
        if (fd < 0)
            return nullptr;
        struct stat64 sStat;
        if (fstat64(fd, &sStat) != 0 || !S_ISREG(sStat.st_mode))
        {
            close(fd);
            errno = EACCES;
            return nullptr;
        }
        return VSIVirtualHandleUniquePtr(new RegularFileReadHandle(fd));
    }

    int Stat(const char *pszFilename, VSIStatBufL *pStatBuf, int) override
    {
        return stat64(pszFilename, pStatBuf);
    }

    char **ReadDirEx(const char *pszPath, int nMaxFiles) override
    {
        if (*pszPath == '\0')
            pszPath = ".";
        CPLStringList aosDir;
        DIR *hDir = opendir(pszPath);
        if (hDir)
        {
            aosDir.Assign(static_cast<char **>(CPLCalloc(2, sizeof(char *))));
            while (const struct dirent *psEntry = readdir(hDir))
            {
                aosDir.AddString(psEntry->d_name);
                if (nMaxFiles > 0 && aosDir.Count() > nMaxFiles)
                    break;
            }
            closedir(hDir);
        }
        return aosDir.StealList();
    }

    int IsCaseSensitive(const char *) override
    {
        return TRUE;
    }

    bool IsLocal(const char *) const override
    {
        return true;
    }
};

class DisabledFilesystem final : public VSIFilesystemHandler
{
  public:
    VSIVirtualHandleUniquePtr Open(const char *, const char *, bool, CSLConstList) override
    {
        errno = ENOENT;
        return nullptr;
    }

    int Stat(const char *, VSIStatBufL *, int) override
    {
        errno = ENOENT;
        return -1;
    }
};
}  // namespace

__attribute__((constructor)) static void ContainVSIFilesystems()
{
    VSIFileManager::InstallHandler("", std::make_shared<ReadOnlyRealFilesystem>());
    const auto poDisabled = std::make_shared<DisabledFilesystem>();
    for (const char *pszPrefix : {"/vsistdin/", "/vsistdin?", "/vsistdout/"})
        VSIFileManager::InstallHandler(pszPrefix, poDisabled);
}
