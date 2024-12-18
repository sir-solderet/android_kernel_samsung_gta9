// SPDX-License-Identifier: GPL-2.0
/*
 * Samsung Specific feature
 *
 * Copyright (C) 2021 Samsung Electronics Co., Ltd.
 *
 * Authors:
 *      Storage Driver <storage.sec@samsung.com>
 */
#ifndef __MMC_SEC_SYSFS_H__
#define __MMC_SEC_SYSFS_H__

#include <linux/mmc/host.h>

void mmc_sec_init_sysfs(struct mmc_host *mmc);

extern struct sd_sec_vendor_info svi;

#endif