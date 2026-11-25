// SPDX-License-Identifier: GPL-2.0
/*
 * Workaround for ASUS Vivobook battery firmware (first seen on the M1607KA):
 * while running on battery, _BST sometimes reports neither "charging" nor
 * "discharging", so the ACPI battery driver reports
 * POWER_SUPPLY_STATUS_NOT_CHARGING about every other second. At 100% charge
 * the same empty state makes the driver report POWER_SUPPLY_STATUS_FULL
 * instead. Userspace (upower) shows these as the charger being connected or
 * the battery being full.
 *
 * This module hooks acpi_battery_get_property() with a kretprobe and rewrites
 * NOT_CHARGING or FULL to DISCHARGING whenever the AC adapter is offline.
 *
 * The probe handler runs in atomic context and must not sleep, but reading
 * the AC adapter state evaluates ACPI methods (which can sleep). So the AC
 * state is cached: a power_supply notifier queues a work item that re-reads
 * it whenever the adapter reports a change, and a periodic poll recovers if
 * an adapter notification is missed.
 */

#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/kprobes.h>
#include <linux/jiffies.h>
#include <linux/module.h>
#include <linux/power_supply.h>
#include <linux/workqueue.h>

static char *ac_name = "ADP0";
module_param(ac_name, charp, 0444);
MODULE_PARM_DESC(ac_name, "Name of the AC adapter power supply (default: ADP0)");

static struct power_supply *ac_psy;
static bool ac_online = true;	/* assume online until read: never rewrite by mistake */
static bool stopping;
static unsigned long fixed_count;

static void ac_update(void)
{
	union power_supply_propval val;

	if (!READ_ONCE(stopping) &&
	    !power_supply_get_property(ac_psy, POWER_SUPPLY_PROP_ONLINE, &val))
		WRITE_ONCE(ac_online, val.intval != 0);
}

static void ac_refresh(struct work_struct *work);
static DECLARE_DELAYED_WORK(ac_work, ac_refresh);

static void ac_refresh(struct work_struct *work)
{
	ac_update();
	if (!READ_ONCE(stopping))
		schedule_delayed_work(to_delayed_work(work), HZ);
}

static int psy_notify(struct notifier_block *nb, unsigned long event, void *data)
{
	if (data == ac_psy && !READ_ONCE(stopping))
		mod_delayed_work(system_wq, &ac_work, 0);
	return NOTIFY_OK;
}

static struct notifier_block psy_nb = {
	.notifier_call = psy_notify,
};

struct probe_data {
	enum power_supply_property psp;
	union power_supply_propval *val;
};

/*
 * static int acpi_battery_get_property(struct power_supply *psy,
 *				       enum power_supply_property psp,
 *				       union power_supply_propval *val)
 */
static int get_property_entry(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct probe_data *d = (struct probe_data *)ri->data;

	d->psp = regs_get_kernel_argument(regs, 1);
	d->val = (union power_supply_propval *)regs_get_kernel_argument(regs, 2);

	/* Only the status property is interesting; skip the return handler otherwise. */
	return d->psp == POWER_SUPPLY_PROP_STATUS ? 0 : 1;
}

static int get_property_ret(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct probe_data *d = (struct probe_data *)ri->data;

	if (regs_return_value(regs) != 0)
		return 0;
	if ((d->val->intval == POWER_SUPPLY_STATUS_NOT_CHARGING ||
	     d->val->intval == POWER_SUPPLY_STATUS_FULL) && !READ_ONCE(ac_online)) {
		d->val->intval = POWER_SUPPLY_STATUS_DISCHARGING;
		fixed_count++;
	}
	return 0;
}

static struct kretprobe krp = {
	.kp.symbol_name	= "acpi_battery_get_property",
	.entry_handler	= get_property_entry,
	.handler	= get_property_ret,
	.data_size	= sizeof(struct probe_data),
	.maxactive	= 16,
};

static int __init asus_bat_fix_init(void)
{
	int ret;

	ac_psy = power_supply_get_by_name(ac_name);
	if (!ac_psy) {
		pr_err("power supply '%s' not found\n", ac_name);
		return -ENODEV;
	}
	WRITE_ONCE(stopping, false);

	ret = power_supply_reg_notifier(&psy_nb);
	if (ret)
		goto err_put;

	/* Read the initial AC state before the probe can act on it. */
	ac_update();

	ret = register_kretprobe(&krp);
	if (ret) {
		pr_err("register_kretprobe failed: %d\n", ret);
		goto err_notifier;
	}
	schedule_delayed_work(&ac_work, HZ);

	pr_info("loaded, AC adapter %s is %s\n", ac_name,
		READ_ONCE(ac_online) ? "online" : "offline");
	return 0;

err_notifier:
	WRITE_ONCE(stopping, true);
	power_supply_unreg_notifier(&psy_nb);
	cancel_delayed_work_sync(&ac_work);
err_put:
	power_supply_put(ac_psy);
	return ret;
}

static void __exit asus_bat_fix_exit(void)
{
	WRITE_ONCE(stopping, true);
	unregister_kretprobe(&krp);
	power_supply_unreg_notifier(&psy_nb);
	cancel_delayed_work_sync(&ac_work);
	power_supply_put(ac_psy);
	pr_info("unloaded, corrected %lu status reads\n", fixed_count);
}

module_init(asus_bat_fix_init);
module_exit(asus_bat_fix_exit);

MODULE_LICENSE("GPL");
MODULE_VERSION("1.2");
MODULE_DESCRIPTION("Report Discharging instead of stale battery statuses on ASUS Vivobooks");
