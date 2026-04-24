# secret
# md5sum("# secret") should be 92b12a37d1913ac41d2956120a475aca
# for avoiding hassle with factory u-boot
# secret has not yet been found
fatload mmc 0:1 0x80800000 /u-boot-ml.bin
go 0x80800000
