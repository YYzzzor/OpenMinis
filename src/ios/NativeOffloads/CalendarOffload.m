//
//  CalendarOffload.m
//  MinisApp
//
//  Native offload handler for `apple-calendar`.
//  Subcommands: list, reminders, freebusy, calendars, create, remind
//

#import <Foundation/Foundation.h>
#import <EventKit/EventKit.h>
#import <UIKit/UIKit.h>
#import "NativeOffloadUtils.h"
#import "CalendarOffload.h"
#include "kernel/native_offload.h"
#include <unistd.h>

static NSString *const TOOL_NAME = @"apple-calendar";
static const NSInteger DEFAULT_LIMIT = 100;

static NSString *const HELP_TEXT =
    @"apple-calendar - Query and manage iOS calendar events and reminders\n"
     "\n"
     "USAGE:\n"
     "  apple-calendar <command> [options]\n"
     "\n"
     "COMMANDS:\n"
     "  list              List calendar events\n"
     "  reminders         List reminders\n"
     "  freebusy          Show free/busy time slots\n"
     "  calendars         List all calendars\n"
     "  create            Create a new event\n"
     "  update            Update an existing event\n"
     "  delete            Delete an event\n"
     "  remind            Create a new reminder\n"
     "  update-reminder   Update an existing reminder\n"
     "  complete-reminder Complete or uncomplete a reminder\n"
     "  delete-reminder   Delete a reminder\n"
     "\n"
     "COMMON OPTIONS:\n"
     "  --help, -h           Show this help message\n"
     "  --compact            Minimize JSON output\n"
     "  -q, --quiet          Output only data field\n"
     "\n"
     "DATE OPTIONS:\n"
     "  --start <datetime>   Start time (ISO 8601 or relative: -7d, -2h)\n"
     "  --end <datetime>     End time\n"
     "  --days <N>           Last N days\n"
     "  --today              Equivalent to --days 1\n"
     "  --limit <N>          Maximum number of results\n"
     "\n"
     "LIST OPTIONS:\n"
     "  --calendar <name>    Filter by calendar name\n"
     "\n"
     "CREATE OPTIONS:\n"
     "  --title <title>      Event title (required)\n"
     "  --start <datetime>   Start time (required)\n"
     "  --end <datetime>     End time (required)\n"
     "  --calendar <name>    Calendar to add to\n"
     "  --location <loc>     Event location\n"
     "  --notes <text>       Event notes\n"
     "  --alarm <minutes>    Alarm minutes before event\n"
     "\n"
     "  --time-zone <IANA>  Event time zone (recurring default: device local)\n"
     "                       Use explicit offsets in --start/--end when selecting a zone.\n"
     "\n"
     "RECURRENCE OPTIONS (create only; one native EventKit rule):\n"
     "  --recurrence <daily|weekly|monthly|yearly>\n"
     "  --recurrence-interval <N>       Positive interval (default: 1; weekly + 2 = biweekly)\n"
     "  --recurrence-days-of-week <list>  MO,TU,WE,TH,FR,SA,SU; weekly/monthly/yearly\n"
     "                       Monthly/yearly also accept 2TU,-1FR (ordinal +/-1..53).\n"
     "  --recurrence-days-of-month <list>  +/-1..31, no 0; monthly only\n"
     "  --recurrence-months-of-year <list> 1..12; yearly only\n"
     "  --recurrence-weeks-of-year <list>  +/-1..53, no 0; yearly only\n"
     "                       WARNING: future expansion failed on tested iOS simulators;\n"
     "                       check returned warnings and verify future dates with list.\n"
     "  --recurrence-days-of-year <list>   +/-1..366, no 0; yearly only\n"
     "  --recurrence-set-positions <list>  +/-1..366, no 0; requires a date selector\n"
     "                       Lists are comma-separated; negative values count backwards.\n"
     "                       Set positions filter matching dates within each period.\n"
     "  --recurrence-count <N>          Stop after N occurrences, including the first\n"
     "  --recurrence-until <date>       Inclusive YYYY-MM-DD in event zone, or ISO 8601\n"
     "                       datetime with offset. Count/until are mutually exclusive.\n"
     "                       Omit both to repeat forever. Start must match the pattern.\n"
     "                       Invalid frequency/selector combinations are rejected.\n"
     "                       Week start/calendar identifier are managed by EventKit.\n"
     "\n"
     "REMIND OPTIONS:\n"
     "  --title <title>      Reminder title (required)\n"
     "  --due <datetime>     Due date\n"
     "  --list <name>        Reminder list name\n"
     "  --priority <0-9>     Priority level\n"
     "  --notes <text>       Reminder notes\n"
     "\n"
     "UPDATE OPTIONS:\n"
     "  --id <event_id>      Event ID (required, from list output)\n"
     "  --title <title>      New title\n"
     "  --start <datetime>   New start time\n"
     "  --end <datetime>     New end time\n"
     "  --calendar <name>    Move to a different calendar\n"
     "  --location <loc>     New location\n"
     "  --notes <text>       New notes\n"
     "  --alarm <minutes>    New alarm (replaces existing)\n"
     "  --occurrence-date <datetime>  For recurring events: the start of the specific\n"
     "                       occurrence to edit (from list 'occurrence_date'). Without it,\n"
     "                       the series master is edited. Falls back to --start if omitted.\n"
     "  --span <this|future|all>  Scope of change for recurring events (default: this).\n"
     "                       this = only this occurrence; future/all = this and later.\n"
     "\n"
     "DELETE OPTIONS:\n"
     "  --id <event_id>      Event ID (required, from list output)\n"
     "  --occurrence-date <datetime>  For recurring events: the start of the specific\n"
     "                       occurrence to delete (from list 'occurrence_date').\n"
     "  --span <this|future|all>  Scope of deletion for recurring events (default: this).\n"
     "\n"
     "UPDATE-REMINDER OPTIONS:\n"
     "  --id <reminder_id>   Reminder ID (required)\n"
     "  --title <title>      New title\n"
     "  --due <datetime>     New due date\n"
     "  --list <name>        Move to a different list\n"
     "  --priority <0-9>     New priority\n"
     "  --notes <text>       New notes\n"
     "\n"
     "COMPLETE-REMINDER OPTIONS:\n"
     "  --id <reminder_id>   Reminder ID (required)\n"
     "  --undo               Mark as incomplete instead\n"
     "\n"
     "DELETE-REMINDER OPTIONS:\n"
     "  --id <reminder_id>   Reminder ID (required)\n"
     "\n"
     "EXAMPLES:\n"
     "  apple-calendar list --today\n"
     "  apple-calendar list --days 7 --compact -q\n"
     "  apple-calendar freebusy --start 2026-02-24T09:00 --end 2026-02-24T18:00\n"
     "  apple-calendar create --title \"Meeting\" --start 2026-02-25T14:00 --end 2026-02-25T15:00\n"
     "  apple-calendar remind --title \"Buy groceries\" --due 2026-02-25T18:00\n"
     "  apple-calendar create --title \"Biweekly meeting\" --start 2027-01-01T09:00:00+08:00 --end 2027-01-01T10:00:00+08:00 --time-zone Asia/Shanghai --recurrence weekly --recurrence-interval 2 --recurrence-count 10\n"
     "  apple-calendar calendars\n";

// Shared EKEventStore (thread-safe, single instance is recommended)
static EKEventStore *_eventStore = nil;
static EKEventStore *eventStore(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _eventStore = [[EKEventStore alloc] init];
    });
    return _eventStore;
}

// Serial queue to prevent concurrent authorization dialogs
static dispatch_queue_t authQueue(void) {
    static dispatch_queue_t q = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        q = dispatch_queue_create("com.openminis.calendar.auth", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

// Request calendar access synchronously via semaphore
static BOOL requestCalendarAccess(NSString **outError) {
    __block BOOL granted = NO;
    __block NSError *authError = nil;

    dispatch_sync(authQueue(), ^{
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        if (@available(iOS 17.0, *)) {
            [eventStore() requestFullAccessToEventsWithCompletion:^(BOOL g, NSError *e) {
                granted = g;
                authError = e;
                dispatch_semaphore_signal(sem);
            }];
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [eventStore() requestAccessToEntityType:EKEntityTypeEvent completion:^(BOOL g, NSError *e) {
                granted = g;
                authError = e;
                dispatch_semaphore_signal(sem);
            }];
#pragma clang diagnostic pop
        }
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    });

    if (!granted && outError) {
        NSString *reason = authError.localizedDescription ?: @"Calendar access not granted";
        *outError = [NSString stringWithFormat:
            @"%@. To grant access, open Settings > Privacy & Security > Calendars "
             "and enable MinisX.", reason];
    }
    return granted;
}

static BOOL requestRemindersAccess(NSString **outError) {
    __block BOOL granted = NO;
    __block NSError *authError = nil;

    dispatch_sync(authQueue(), ^{
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        if (@available(iOS 17.0, *)) {
            [eventStore() requestFullAccessToRemindersWithCompletion:^(BOOL g, NSError *e) {
                granted = g;
                authError = e;
                dispatch_semaphore_signal(sem);
            }];
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [eventStore() requestAccessToEntityType:EKEntityTypeReminder completion:^(BOOL g, NSError *e) {
                granted = g;
                authError = e;
                dispatch_semaphore_signal(sem);
            }];
#pragma clang diagnostic pop
        }
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    });

    if (!granted && outError) {
        NSString *reason = authError.localizedDescription ?: @"Reminders access not granted";
        *outError = [NSString stringWithFormat:
            @"%@. To grant access, open Settings > Privacy & Security > Reminders "
             "and enable MinisX.", reason];
    }
    return granted;
}

// Compute date range from args
static void resolve_date_range(int argc, char **argv, NSDate **start, NSDate **end) {
    if (noff_has_flag(argc, argv, "--today")) {
        NSCalendar *cal = [NSCalendar currentCalendar];
        *start = [cal startOfDayForDate:[NSDate date]];
        *end = [cal dateByAddingUnit:NSCalendarUnitDay value:1 toDate:*start options:0];
        return;
    }

    NSString *daysStr = noff_find_arg(argc, argv, "--days");
    if (daysStr) {
        NSInteger days = [daysStr integerValue];
        if (days <= 0) days = 7;
        NSCalendar *cal = [NSCalendar currentCalendar];
        *start = [cal startOfDayForDate:[NSDate dateWithTimeIntervalSinceNow:-days * 86400]];
        *end = [NSDate date];
        return;
    }

    NSString *startStr = noff_find_arg(argc, argv, "--start");
    NSString *endStr = noff_find_arg(argc, argv, "--end");
    *start = startStr ? noff_parse_date(startStr) : [NSDate dateWithTimeIntervalSinceNow:-86400];
    *end = endStr ? noff_parse_date(endStr) : [NSDate date];
}

// EventKit 对不适用的字段会静默忽略；在保存前拒绝这些输入，防止规则被降级。
static BOOL recurrence_integer(NSString *text, NSInteger minimum, NSInteger maximum,
                               BOOL allowZero, NSInteger *value) {
    if (!text.length) return NO;
    NSScanner *scanner = [NSScanner scannerWithString:text];
    scanner.charactersToBeSkipped = nil;
    long long parsed = 0;
    if (![scanner scanLongLong:&parsed] || !scanner.isAtEnd ||
        parsed < minimum || parsed > maximum || (!allowZero && parsed == 0)) return NO;
    // scanLongLong 会将溢出截成 LLONG_MAX/MIN；往返比较同时拒绝小数和溢出。
    NSString *canonical = [NSString stringWithFormat:@"%lld", parsed];
    NSString *unsignedText = [text hasPrefix:@"+"] ? [text substringFromIndex:1] : text;
    if (![canonical isEqualToString:unsignedText]) return NO;
    *value = (NSInteger)parsed;
    return YES;
}

static NSArray<NSNumber *> *recurrence_numbers(NSString *text, NSInteger minimum,
                                               NSInteger maximum, NSString **error) {
    if (!text) return nil;
    NSMutableOrderedSet *result = [NSMutableOrderedSet orderedSet];
    for (NSString *part in [text componentsSeparatedByString:@","]) {
        NSInteger value;
        if (!recurrence_integer(part, minimum, maximum, NO, &value)) {
            *error = [NSString stringWithFormat:@"Expected comma-separated integers in %ld...%ld, excluding 0: %@",
                      (long)minimum, (long)maximum, text];
            return nil;
        }
        [result addObject:@(value)];
    }
    return result.array;
}

static BOOL calendar_option_has_value(NSString *key) {
    return [@[@"--title", @"--start", @"--end", @"--calendar", @"--location", @"--notes",
              @"--alarm", @"--time-zone", @"--id", @"--occurrence-date", @"--span",
              @"--days", @"--limit", @"--due", @"--list", @"--priority"] containsObject:key];
}

// 只在选项位置匹配；字符串取值可以合法包含另一个选项的名称。
static int calendar_option_index(int argc, char **argv, const char *name) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], name) == 0) return i;
        NSString *key = [NSString stringWithUTF8String:argv[i]];
        if (calendar_option_has_value(key) || [key hasPrefix:@"--recurrence"]) i++;
    }
    return -1;
}

static NSString *calendar_option_value(int argc, char **argv, const char *name) {
    int index = calendar_option_index(argc, argv, name);
    return index >= 0 && index + 1 < argc ? [NSString stringWithUTF8String:argv[index + 1]] : nil;
}

static NSDate *recurrence_end_datetime(NSString *text) {
    // Foundation 会容忍非法日期和尾随字符；先校验完整格式与日期组件，禁止自动修正。
    NSString *pattern = @"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]{1,9})?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])$";
    NSRange match = [text rangeOfString:pattern options:NSRegularExpressionSearch];
    if (match.location != 0 || match.length != text.length) return nil;
    NSString *wallTime = [text substringToIndex:19];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss";
    formatter.lenient = NO;
    NSDate *componentsDate = [formatter dateFromString:wallTime];
    if (!componentsDate || ![[formatter stringFromDate:componentsDate] isEqualToString:wallTime]) return nil;
    NSISO8601DateFormatter *iso = [[NSISO8601DateFormatter alloc] init];
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    if ([text containsString:@"."]) iso.formatOptions |= NSISO8601DateFormatWithFractionalSeconds;
    return [iso dateFromString:text];
}

static BOOL parse_recurrence(int argc, char **argv, NSDate *start, NSTimeZone *timeZone,
                             EKRecurrenceRule **rule, NSString **error) {
    *rule = nil;
    NSArray *names = @[@"--recurrence", @"--recurrence-interval", @"--recurrence-days-of-week",
                      @"--recurrence-days-of-month", @"--recurrence-months-of-year",
                      @"--recurrence-weeks-of-year", @"--recurrence-days-of-year",
                      @"--recurrence-set-positions", @"--recurrence-count", @"--recurrence-until"];
    NSMutableDictionary<NSString *, NSString *> *options = [NSMutableDictionary dictionary];
    for (int i = 2; i < argc; i++) {
        NSString *key = [NSString stringWithUTF8String:argv[i]];
        if (calendar_option_has_value(key)) { i++; continue; }
        if (![key hasPrefix:@"--recurrence"]) {
            if ([@[@"--compact", @"--quiet", @"-q"] containsObject:key]) continue;
            *error = [NSString stringWithFormat:@"Unknown create option: %@. See --help.", key];
            return NO;
        }
        if (![names containsObject:key] || options[key] || i + 1 >= argc ||
            !strlen(argv[i + 1]) || strncmp(argv[i + 1], "--", 2) == 0) {
            *error = [NSString stringWithFormat:@"Unknown, duplicated, or missing value for %@. See --help.", key];
            return NO;
        }
        options[key] = [NSString stringWithUTF8String:argv[++i]];
    }
    if (!options.count) return YES;
    NSArray *frequencies = @[@"daily", @"weekly", @"monthly", @"yearly"];
    NSString *frequencyName = [options[@"--recurrence"] lowercaseString];
    NSUInteger index = frequencyName ? [frequencies indexOfObject:frequencyName] : NSNotFound;
    if (index == NSNotFound) {
        *error = @"Recurrence options require --recurrence daily|weekly|monthly|yearly.";
        return NO;
    }
    EKRecurrenceFrequency frequency = (EKRecurrenceFrequency)index;
    NSInteger interval = 1;
    if (options[@"--recurrence-interval"] &&
        !recurrence_integer(options[@"--recurrence-interval"], 1, NSIntegerMax, NO, &interval)) {
        *error = @"--recurrence-interval must be a positive integer.";
        return NO;
    }
    NSDictionary *requiredFrequency = @{@"--recurrence-days-of-month": @"monthly",
                                        @"--recurrence-months-of-year": @"yearly",
                                        @"--recurrence-weeks-of-year": @"yearly",
                                        @"--recurrence-days-of-year": @"yearly"};
    for (NSString *key in requiredFrequency) {
        if (options[key] && ![frequencyName isEqualToString:requiredFrequency[key]]) {
            *error = [NSString stringWithFormat:@"%@ requires --recurrence %@ (EventKit otherwise ignores it).",
                      key, requiredFrequency[key]];
            return NO;
        }
    }
    NSMutableArray<EKRecurrenceDayOfWeek *> *weekdays = nil;
    if (options[@"--recurrence-days-of-week"]) {
        if (frequency == EKRecurrenceFrequencyDaily) {
            *error = @"--recurrence-days-of-week is only valid for weekly, monthly, or yearly recurrence.";
            return NO;
        }
        weekdays = [NSMutableArray array];
        NSArray *dayNames = @[@"SU", @"MO", @"TU", @"WE", @"TH", @"FR", @"SA"];
        for (NSString *raw in [options[@"--recurrence-days-of-week"] componentsSeparatedByString:@","]) {
            NSString *token = raw.uppercaseString;
            NSString *suffix = token.length >= 2 ? [token substringFromIndex:token.length - 2] : @"";
            NSUInteger day = [dayNames indexOfObject:suffix];
            NSInteger ordinal = 0;
            BOOL hasOrdinal = token.length > 2;
            if (day == NSNotFound || (hasOrdinal &&
                !recurrence_integer([token substringToIndex:token.length - 2], -53, 53, NO, &ordinal)) ||
                (hasOrdinal && frequency == EKRecurrenceFrequencyWeekly)) {
                *error = @"Weekdays use MO,TU,WE,TH,FR,SA,SU; monthly/yearly also accept ordinals -53...-1 or 1...53, e.g. 2TU,-1FR.";
                return NO;
            }
            [weekdays addObject:hasOrdinal ? [EKRecurrenceDayOfWeek dayOfWeek:(EKWeekday)(day + 1) weekNumber:ordinal]
                                          : [EKRecurrenceDayOfWeek dayOfWeek:(EKWeekday)(day + 1)]];
        }
    }
    NSArray *monthDays = recurrence_numbers(options[@"--recurrence-days-of-month"], -31, 31, error);
    if (*error) return NO;
    NSArray *months = recurrence_numbers(options[@"--recurrence-months-of-year"], 1, 12, error);
    if (*error) return NO;
    NSArray *weeks = recurrence_numbers(options[@"--recurrence-weeks-of-year"], -53, 53, error);
    if (*error) return NO;
    NSArray *yearDays = recurrence_numbers(options[@"--recurrence-days-of-year"], -366, 366, error);
    if (*error) return NO;
    NSArray *positions = recurrence_numbers(options[@"--recurrence-set-positions"], -366, 366, error);
    if (*error) return NO;
    BOOL complex = weekdays || monthDays || months || weeks || yearDays;
    if (positions && !complex) {
        *error = @"--recurrence-set-positions requires at least one recurrence date selector.";
        return NO;
    }
    EKRecurrenceEnd *end = nil;
    if (options[@"--recurrence-count"] && options[@"--recurrence-until"]) {
        *error = @"Use either --recurrence-count or --recurrence-until, not both.";
        return NO;
    }
    if (options[@"--recurrence-count"]) {
        NSInteger count;
        if (!recurrence_integer(options[@"--recurrence-count"], 1, NSIntegerMax, NO, &count)) {
            *error = @"--recurrence-count must be a positive integer, including the first occurrence.";
            return NO;
        }
        end = [EKRecurrenceEnd recurrenceEndWithOccurrenceCount:(NSUInteger)count];
    }
    if (options[@"--recurrence-until"]) {
        NSString *text = options[@"--recurrence-until"];
        NSDate *until = nil;
        NSDateFormatter *dateOnly = [[NSDateFormatter alloc] init];
        dateOnly.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        dateOnly.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        dateOnly.timeZone = timeZone;
        dateOnly.dateFormat = @"yyyy-MM-dd";
        dateOnly.lenient = NO;
        if (text.length == 10) {
            until = [dateOnly dateFromString:text];
            if (until && ![[dateOnly stringFromDate:until] isEqualToString:text]) until = nil;
            if (until) {
                // 仅日期表示包含当日；按日历加一天，不能在夏令时切换日固定加 86400 秒。
                NSCalendar *calendar = dateOnly.calendar;
                calendar.timeZone = timeZone;
                until = [[calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:until options:0]
                         dateByAddingTimeInterval:-1];
            }
        } else {
            until = recurrence_end_datetime(text);
        }
        if (!until || [until compare:start] == NSOrderedAscending) {
            *error = @"--recurrence-until must be YYYY-MM-DD or an ISO 8601 datetime with timezone, on/after the first start.";
            return NO;
        }
        end = [EKRecurrenceEnd recurrenceEndWithEndDate:until];
    }
    @try {
        *rule = complex ? [[EKRecurrenceRule alloc] initRecurrenceWithFrequency:frequency interval:interval
                         daysOfTheWeek:weekdays daysOfTheMonth:monthDays monthsOfTheYear:months
                         weeksOfTheYear:weeks daysOfTheYear:yearDays setPositions:positions end:end]
                        : [[EKRecurrenceRule alloc] initRecurrenceWithFrequency:frequency interval:interval end:end];
    } @catch (NSException *exception) {
        *error = [NSString stringWithFormat:@"Invalid EventKit recurrence: %@", exception.reason];
        return NO;
    }
    if (!*rule) {
        *error = @"EventKit could not create this recurrence rule.";
        return NO;
    }
    return YES;
}

static NSArray *recurrence_to_array(EKEvent *event) {
    NSMutableArray *result = [NSMutableArray array];
    NSArray *frequencies = @[@"daily", @"weekly", @"monthly", @"yearly"];
    NSArray *names = @[@"SU", @"MO", @"TU", @"WE", @"TH", @"FR", @"SA"];
    for (EKRecurrenceRule *rule in event.recurrenceRules) {
        NSMutableArray *days = [NSMutableArray array];
        for (EKRecurrenceDayOfWeek *day in rule.daysOfTheWeek) {
            NSString *name = names[day.dayOfTheWeek - 1];
            [days addObject:day.weekNumber ? [NSString stringWithFormat:@"%ld%@", (long)day.weekNumber, name] : name];
        }
        EKRecurrenceEnd *end = rule.recurrenceEnd;
        NSDictionary *ending = !end ? @{@"type": @"never"}
            : end.endDate ? @{@"type": @"until", @"date": noff_format_date(end.endDate)}
            : @{@"type": @"count", @"count": @(end.occurrenceCount)};
        [result addObject:@{@"frequency": frequencies[rule.frequency], @"interval": @(rule.interval),
                           @"days_of_week": days, @"days_of_month": rule.daysOfTheMonth ?: @[],
                           @"months_of_year": rule.monthsOfTheYear ?: @[], @"weeks_of_year": rule.weeksOfTheYear ?: @[],
                           @"days_of_year": rule.daysOfTheYear ?: @[], @"set_positions": rule.setPositions ?: @[],
                           @"end": ending, @"calendar_identifier": rule.calendarIdentifier ?: @"",
                           @"first_day_of_week": @(rule.firstDayOfTheWeek)}];
    }
    return result;
}

static NSArray<NSString *> *recurrence_warnings(EKEvent *event) {
    for (EKRecurrenceRule *rule in event.recurrenceRules) {
        if (rule.weeksOfTheYear.count) {
            // iOS 26.4/27 模拟器的直接 EventKit 对照也无法展开 BYWEEKNO；真机尚未验证。
            return @[@"EventKit saved the yearly week-number rule, but iOS 26.4/27 simulator tests did not expand future occurrences, including direct EventKit controls. Physical-device behavior is unverified. Do not report recurrence as verified without checking future dates with list."];
        }
    }
    return @[];
}

static NSDictionary *event_to_dict(EKEvent *event) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"id"] = event.eventIdentifier ?: @"";
    d[@"title"] = event.title ?: @"";
    // For recurring events, `id` (eventIdentifier) is a series-level ID shared by every
    // occurrence. `occurrence_date` (the start of THIS instance) is what disambiguates a
    // single occurrence so update/delete can target it instead of the series master.
    d[@"is_recurring"] = @(event.hasRecurrenceRules);
    d[@"recurrence_rules"] = recurrence_to_array(event);
    if (recurrence_warnings(event).count) d[@"warnings"] = recurrence_warnings(event);
    d[@"time_zone"] = event.timeZone.name ?: [NSNull null];
    d[@"occurrence_date"] = event.startDate ? noff_format_date(event.startDate) : [NSNull null];
    d[@"start"] = event.startDate ? noff_format_date(event.startDate) : [NSNull null];
    d[@"end"] = event.endDate ? noff_format_date(event.endDate) : [NSNull null];
    d[@"location"] = event.location ?: [NSNull null];
    d[@"calendar"] = event.calendar.title ?: @"";
    d[@"is_all_day"] = @(event.isAllDay);
    d[@"notes"] = event.notes ?: [NSNull null];
    d[@"url"] = event.URL.absoluteString ?: [NSNull null];

    if (event.hasAlarms && event.alarms.count > 0) {
        NSMutableArray *alarms = [NSMutableArray array];
        for (EKAlarm *alarm in event.alarms) {
            [alarms addObject:@{@"minutes_before": @(-alarm.relativeOffset / 60.0)}];
        }
        d[@"alarms"] = alarms;
    }

    if (event.attendees.count > 0) {
        NSMutableArray *attendees = [NSMutableArray array];
        for (EKParticipant *p in event.attendees) {
            NSString *status;
            switch (p.participantStatus) {
                case EKParticipantStatusAccepted: status = @"accepted"; break;
                case EKParticipantStatusDeclined: status = @"declined"; break;
                case EKParticipantStatusTentative: status = @"tentative"; break;
                default: status = @"pending"; break;
            }
            [attendees addObject:@{
                @"name": p.name ?: @"",
                @"status": status,
            }];
        }
        d[@"attendees"] = attendees;
    }

    return d;
}

static int cmd_list(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *authErr = nil;
    if (!requestCalendarAccess(&authErr)) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"list",
                                             NOFF_ERR_AUTHORIZATION_DENIED, authErr);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_AUTH_DENIED;
    }

    NSDate *start, *end;
    resolve_date_range(argc, argv, &start, &end);

    if (!start || !end) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"list",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Invalid or missing date range. Check --start/--end format (ISO 8601 or relative like -7d).");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    // EKEventStore throws NSException if start > end
    if ([start compare:end] == NSOrderedDescending) {
        NSDate *tmp = start;
        start = end;
        end = tmp;
    }

    NSString *limitStr = noff_find_arg(argc, argv, "--limit");
    NSInteger limit = limitStr ? [limitStr integerValue] : DEFAULT_LIMIT;

    NSString *calFilter = noff_find_arg(argc, argv, "--calendar");

    NSPredicate *pred;
    @try {
        pred = [eventStore() predicateForEventsWithStartDate:start
                                                     endDate:end
                                                   calendars:nil];
    } @catch (NSException *e) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"list",
                                             NOFF_ERR_INVALID_ARGS,
                                             [NSString stringWithFormat:@"Failed to create event predicate: %@", e.reason]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSArray<EKEvent *> *events = [eventStore() eventsMatchingPredicate:pred];
    events = [events sortedArrayUsingSelector:@selector(compareStartDateWithEvent:)];

    if (calFilter) {
        events = [events filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(EKEvent *e, NSDictionary *b) {
                return [e.calendar.title localizedCaseInsensitiveContainsString:calFilter];
            }]];
    }

    NSInteger totalFiltered = (NSInteger)events.count;
    if (totalFiltered > limit) {
        events = [events subarrayWithRange:NSMakeRange(0, limit)];
    }

    NSMutableArray *eventDicts = [NSMutableArray array];
    for (EKEvent *e in events) {
        [eventDicts addObject:event_to_dict(e)];
    }

    NSMutableDictionary *data = [@{
        @"events": eventDicts,
        @"range": @{
            @"start": noff_format_date(start),
            @"end": noff_format_date(end),
        },
        @"count": @(eventDicts.count),
    } mutableCopy];
    if (totalFiltered > limit) {
        data[@"_warning"] = [NSString stringWithFormat:
            @"Results truncated by --limit. Returned %ld of %ld total records. "
             "Use a larger --limit to retrieve more data.",
            (long)limit, (long)totalFiltered];
        data[@"total_available"] = @(totalFiltered);
    }
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"list", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

int calendar_cmd_reminders(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *authErr = nil;
    if (!requestRemindersAccess(&authErr)) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"reminders",
                                             NOFF_ERR_AUTHORIZATION_DENIED, authErr);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_AUTH_DENIED;
    }

    BOOL showCompleted = noff_has_flag(argc, argv, "--completed");
    BOOL showIncomplete = noff_has_flag(argc, argv, "--incomplete");
    NSString *limitStr = noff_find_arg(argc, argv, "--limit");
    NSInteger limit = limitStr ? [limitStr integerValue] : DEFAULT_LIMIT;
    NSString *listName = noff_find_arg(argc, argv, "--list");

    NSArray<EKCalendar *> *calendars = nil;
    if (listName) {
        NSMutableArray *filtered = [NSMutableArray array];
        for (EKCalendar *cal in [eventStore() calendarsForEntityType:EKEntityTypeReminder]) {
            if ([cal.title localizedCaseInsensitiveContainsString:listName]) {
                [filtered addObject:cal];
            }
        }
        calendars = filtered;
    }

    NSPredicate *pred;
    if (showCompleted) {
        pred = [eventStore() predicateForCompletedRemindersWithCompletionDateStarting:nil
                              ending:nil calendars:calendars];
    } else if (showIncomplete) {
        pred = [eventStore() predicateForIncompleteRemindersWithDueDateStarting:nil
                              ending:nil calendars:calendars];
    } else {
        pred = [eventStore() predicateForRemindersInCalendars:calendars];
    }

    __block NSArray<EKReminder *> *reminders = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [eventStore() fetchRemindersMatchingPredicate:pred completion:^(NSArray *r) {
        reminders = r;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    NSInteger totalCount = (NSInteger)(reminders ?: @[]).count;
    NSMutableArray *items = [NSMutableArray array];
    NSInteger count = 0;
    for (EKReminder *r in reminders) {
        if (count >= limit) break;
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"id"] = r.calendarItemIdentifier ?: @"";
        d[@"title"] = r.title ?: @"";
        d[@"completed"] = @(r.isCompleted);
        d[@"list"] = r.calendar.title ?: @"";
        d[@"priority"] = @(r.priority);
        d[@"notes"] = r.notes ?: [NSNull null];
        if (r.dueDateComponents) {
            NSDate *due = [[NSCalendar currentCalendar] dateFromComponents:r.dueDateComponents];
            d[@"due"] = due ? noff_format_date(due) : [NSNull null];
        }
        [items addObject:d];
        count++;
    }

    NSMutableDictionary *data = [@{
        @"reminders": items,
        @"count": @(items.count),
    } mutableCopy];
    if (totalCount > limit) {
        data[@"_warning"] = [NSString stringWithFormat:
            @"Results truncated by --limit. Returned %ld of %ld total records. "
             "Use a larger --limit to retrieve more data.",
            (long)limit, (long)totalCount];
        data[@"total_available"] = @(totalCount);
    }
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"reminders", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_freebusy(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *authErr = nil;
    if (!requestCalendarAccess(&authErr)) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"freebusy",
                                             NOFF_ERR_AUTHORIZATION_DENIED, authErr);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_AUTH_DENIED;
    }

    NSDate *start, *end;
    resolve_date_range(argc, argv, &start, &end);

    if (!start || !end) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"freebusy",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Invalid or missing date range. Check --start/--end format (ISO 8601 or relative like -7d).");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSPredicate *pred = [eventStore() predicateForEventsWithStartDate:start
                                                              endDate:end
                                                            calendars:nil];
    NSArray<EKEvent *> *events = [eventStore() eventsMatchingPredicate:pred];
    events = [events sortedArrayUsingSelector:@selector(compareStartDateWithEvent:)];

    NSMutableArray *busy = [NSMutableArray array];
    for (EKEvent *e in events) {
        if (e.isAllDay) continue;
        [busy addObject:@{
            @"start": noff_format_date(e.startDate),
            @"end": noff_format_date(e.endDate),
            @"title": e.title ?: @"",
        }];
    }

    // Compute free slots
    NSMutableArray *free = [NSMutableArray array];
    NSDate *cursor = start;
    for (NSDictionary *b in busy) {
        NSDate *busyStart = noff_parse_date(b[@"start"]);
        if ([cursor compare:busyStart] == NSOrderedAscending) {
            [free addObject:@{
                @"start": noff_format_date(cursor),
                @"end": b[@"start"],
            }];
        }
        NSDate *busyEnd = noff_parse_date(b[@"end"]);
        if ([busyEnd compare:cursor] == NSOrderedDescending) {
            cursor = busyEnd;
        }
    }
    if ([cursor compare:end] == NSOrderedAscending) {
        [free addObject:@{
            @"start": noff_format_date(cursor),
            @"end": noff_format_date(end),
        }];
    }

    NSDictionary *data = @{@"busy": busy, @"free": free};
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"freebusy", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_calendars(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *authErr = nil;
    if (!requestCalendarAccess(&authErr)) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"calendars",
                                             NOFF_ERR_AUTHORIZATION_DENIED, authErr);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_AUTH_DENIED;
    }

    NSArray<EKCalendar *> *cals = [eventStore() calendarsForEntityType:EKEntityTypeEvent];
    NSMutableArray *items = [NSMutableArray array];
    for (EKCalendar *cal in cals) {
        CGFloat r, g, b, a;
        [[UIColor colorWithCGColor:cal.CGColor] getRed:&r green:&g blue:&b alpha:&a];
        [items addObject:@{
            @"id": cal.calendarIdentifier,
            @"title": cal.title,
            @"source": cal.source.title ?: @"",
            @"type": cal.isSubscribed ? @"subscription" : @"local",
            @"color": [NSString stringWithFormat:@"#%02X%02X%02X",
                        (int)(r * 255), (int)(g * 255), (int)(b * 255)],
            @"is_default": @([cal.calendarIdentifier isEqualToString:
                              [eventStore() defaultCalendarForNewEvents].calendarIdentifier]),
        }];
    }

    NSDictionary *data = @{@"calendars": items, @"count": @(items.count)};
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"calendars", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int calendar_cmd_create(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *title = calendar_option_value(argc, argv, "--title");
    NSString *startStr = calendar_option_value(argc, argv, "--start");
    NSString *endStr = calendar_option_value(argc, argv, "--end");

    if (!title || !startStr || !endStr) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"create",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Required: --title, --start, --end");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSDate *startDate = noff_parse_date(startStr);
    NSDate *endDate = noff_parse_date(endStr);
    if (!startDate || !endDate) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"create",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Invalid date format for --start or --end");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    // 按选项位置消费取值，避免备注、标题中的 --time-zone 被误当作时区选项。
    NSString *zoneName = nil;
    BOOL zonePresent = NO;
    BOOL invalidZoneOption = NO;
    for (int i = 2; i < argc; i++) {
        NSString *key = [NSString stringWithUTF8String:argv[i]];
        if ([key isEqualToString:@"--time-zone"]) {
            if (zonePresent || i + 1 >= argc || !strlen(argv[i + 1]) ||
                strncmp(argv[i + 1], "--", 2) == 0) invalidZoneOption = YES;
            else zoneName = [NSString stringWithUTF8String:argv[i + 1]];
            zonePresent = YES;
        }
        if (calendar_option_has_value(key) || [key hasPrefix:@"--recurrence"]) i++;
    }
    NSTimeZone *zone = zoneName ? [NSTimeZone timeZoneWithName:zoneName] : [NSTimeZone localTimeZone];
    NSString *recurrenceError = nil;
    EKRecurrenceRule *recurrence = nil;
    if ([endDate compare:startDate] != NSOrderedDescending) {
        recurrenceError = @"--end must be later than --start.";
    } else if (!zone || invalidZoneOption) {
        recurrenceError = @"--time-zone must name an IANA time zone, e.g. Asia/Shanghai.";
    } else {
        parse_recurrence(argc, argv, startDate, zone, &recurrence, &recurrenceError);
    }
    if (recurrenceError) {
        noff_emit_json(stdout_fd, noff_json_error(TOOL_NAME, @"create", NOFF_ERR_INVALID_ARGS,
                                                 recurrenceError), compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSString *authErr = nil;
    if (!requestCalendarAccess(&authErr)) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"create",
                                             NOFF_ERR_AUTHORIZATION_DENIED, authErr);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_AUTH_DENIED;
    }

    EKEvent *event = [EKEvent eventWithEventStore:eventStore()];
    event.title = title;
    event.startDate = startDate;
    event.endDate = endDate;
    // 普通单次事件保留原 EventKit 默认时区行为；重复系列绑定时区，跨夏令时保持当地钟点。
    if (recurrence || zoneName) event.timeZone = zone;
    if (recurrence) [event addRecurrenceRule:recurrence];

    NSString *location = calendar_option_value(argc, argv, "--location");
    if (location) event.location = location;

    NSString *notes = calendar_option_value(argc, argv, "--notes");
    if (notes) event.notes = notes;

    NSString *alarmStr = calendar_option_value(argc, argv, "--alarm");
    if (alarmStr) {
        EKAlarm *alarm = [EKAlarm alarmWithRelativeOffset:-[alarmStr doubleValue] * 60];
        [event addAlarm:alarm];
    }

    // 外部刚创建的日历可能尚未触发缓存更新；刷新来源后再选择，找不到时不能写到默认日历。
    [eventStore() refreshSourcesIfNecessary];
    NSString *calName = calendar_option_value(argc, argv, "--calendar");
    if (calName) {
        for (EKCalendar *cal in [eventStore() calendarsForEntityType:EKEntityTypeEvent]) {
            if ([cal.title localizedCaseInsensitiveContainsString:calName]) {
                event.calendar = cal;
                break;
            }
        }
        if (!event.calendar) {
            noff_emit_json(stdout_fd, noff_json_error(TOOL_NAME, @"create", NOFF_ERR_INVALID_ARGS,
                [NSString stringWithFormat:@"Calendar not found: %@. List calendars and retry.", calName]), compact, quiet);
            return NOFF_EXIT_INVALID_ARGS;
        }
    } else {
        event.calendar = [eventStore() defaultCalendarForNewEvents];
    }

    NSError *saveErr = nil;
    BOOL saved = [eventStore() saveEvent:event span:EKSpanThisEvent commit:YES error:&saveErr];
    if (!saved) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"create",
                                             NOFF_ERR_INTERNAL_ERROR,
                                             saveErr.localizedDescription ?: @"Failed to save event");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    NSMutableDictionary *data = [@{
        @"id": event.eventIdentifier ?: @"",
        @"title": title,
        @"start": noff_format_date(startDate),
        @"end": noff_format_date(endDate),
        @"calendar": event.calendar.title ?: @"",
        @"is_recurring": @(event.hasRecurrenceRules),
        @"recurrence_rules": recurrence_to_array(event),
        @"time_zone": event.timeZone.name ?: [NSNull null],
    } mutableCopy];
    if (recurrence_warnings(event).count) data[@"warnings"] = recurrence_warnings(event);
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"create", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

// Map --span value to an EKSpan. EventKit has no "entire series" span; `future` from the
// first occurrence (the master) covers the whole series, so we treat all/future as
// EKSpanFutureEvents and this (default) as EKSpanThisEvent.
static EKSpan resolve_event_span(int argc, char **argv) {
    NSString *spanStr = noff_find_arg(argc, argv, "--span");
    if (!spanStr) return EKSpanThisEvent;
    NSString *s = [spanStr lowercaseString];
    if ([s isEqualToString:@"future"] || [s isEqualToString:@"all"]) {
        return EKSpanFutureEvents;
    }
    return EKSpanThisEvent;
}

// Resolve the specific EKEvent to operate on.
//
// `eventWithIdentifier:` always returns the series master (first occurrence) for a recurring
// event, so an --id alone cannot target a later occurrence. When the caller supplies an
// occurrence anchor (--occurrence-date, falling back to --start), we enumerate events around
// that instant and return the occurrence whose eventIdentifier matches `eventId` and whose
// startDate is closest to the anchor. Without an anchor we fall back to the legacy
// eventWithIdentifier: behavior.
static EKEvent *resolve_event(int argc, char **argv, NSString *eventId) {
    NSString *anchorStr = noff_find_arg(argc, argv, "--occurrence-date");
    if (!anchorStr) anchorStr = noff_find_arg(argc, argv, "--start");

    NSDate *anchor = anchorStr ? noff_parse_date(anchorStr) : nil;
    if (!anchor) {
        return [eventStore() eventWithIdentifier:eventId];
    }

    // Search a tight window around the anchor (±1 day) and pick the matching occurrence
    // whose start is nearest the anchor.
    NSDate *winStart = [anchor dateByAddingTimeInterval:-86400];
    NSDate *winEnd = [anchor dateByAddingTimeInterval:86400];
    NSPredicate *pred = [eventStore() predicateForEventsWithStartDate:winStart
                                                              endDate:winEnd
                                                            calendars:nil];
    NSArray<EKEvent *> *events = [eventStore() eventsMatchingPredicate:pred];

    EKEvent *best = nil;
    NSTimeInterval bestDelta = DBL_MAX;
    for (EKEvent *e in events) {
        if (![e.eventIdentifier isEqualToString:eventId]) continue;
        NSTimeInterval delta = fabs([e.startDate timeIntervalSinceDate:anchor]);
        if (delta < bestDelta) {
            bestDelta = delta;
            best = e;
        }
    }

    // If no occurrence matched in the window, fall back to the master rather than failing.
    return best ?: [eventStore() eventWithIdentifier:eventId];
}

static int cmd_update(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *authErr = nil;
    if (!requestCalendarAccess(&authErr)) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"update",
                                             NOFF_ERR_AUTHORIZATION_DENIED, authErr);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_AUTH_DENIED;
    }

    NSString *eventId = noff_find_arg(argc, argv, "--id");
    if (!eventId) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"update",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Required: --id <event_id>");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    EKEvent *event = resolve_event(argc, argv, eventId);
    if (!event) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"update",
                                             NOFF_ERR_NO_DATA,
                                             [NSString stringWithFormat:@"Event not found with id '%@'", eventId]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    NSString *title = noff_find_arg(argc, argv, "--title");
    if (title) event.title = title;

    NSString *startStr = noff_find_arg(argc, argv, "--start");
    if (startStr) {
        NSDate *d = noff_parse_date(startStr);
        if (d) event.startDate = d;
    }

    NSString *endStr = noff_find_arg(argc, argv, "--end");
    if (endStr) {
        NSDate *d = noff_parse_date(endStr);
        if (d) event.endDate = d;
    }

    NSString *location = noff_find_arg(argc, argv, "--location");
    if (location) event.location = location;

    NSString *notes = noff_find_arg(argc, argv, "--notes");
    if (notes) event.notes = notes;

    NSString *alarmStr = noff_find_arg(argc, argv, "--alarm");
    if (alarmStr) {
        // Remove existing alarms and set the new one
        for (EKAlarm *a in event.alarms) {
            [event removeAlarm:a];
        }
        EKAlarm *alarm = [EKAlarm alarmWithRelativeOffset:-[alarmStr doubleValue] * 60];
        [event addAlarm:alarm];
    }

    NSString *calName = noff_find_arg(argc, argv, "--calendar");
    if (calName) {
        for (EKCalendar *cal in [eventStore() calendarsForEntityType:EKEntityTypeEvent]) {
            if ([cal.title localizedCaseInsensitiveContainsString:calName]) {
                event.calendar = cal;
                break;
            }
        }
    }

    NSError *saveErr = nil;
    BOOL saved = [eventStore() saveEvent:event span:resolve_event_span(argc, argv) commit:YES error:&saveErr];
    if (!saved) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"update",
                                             NOFF_ERR_INTERNAL_ERROR,
                                             saveErr.localizedDescription ?: @"Failed to update event");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    NSDictionary *data = @{
        @"id": event.eventIdentifier ?: @"",
        @"title": event.title ?: @"",
        @"start": event.startDate ? noff_format_date(event.startDate) : @"",
        @"end": event.endDate ? noff_format_date(event.endDate) : @"",
        @"calendar": event.calendar.title ?: @"",
    };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"update", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_delete(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *authErr = nil;
    if (!requestCalendarAccess(&authErr)) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"delete",
                                             NOFF_ERR_AUTHORIZATION_DENIED, authErr);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_AUTH_DENIED;
    }

    NSString *eventId = noff_find_arg(argc, argv, "--id");
    if (!eventId) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"delete",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Required: --id <event_id>");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    EKEvent *event = resolve_event(argc, argv, eventId);
    if (!event) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"delete",
                                             NOFF_ERR_NO_DATA,
                                             [NSString stringWithFormat:@"Event not found with id '%@'", eventId]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    NSString *eventTitle = event.title ?: @"";
    NSString *calTitle = event.calendar.title ?: @"";
    // Capture the resolved occurrence's start before removal so we can verify the right
    // instance is gone (the series master may still exist after a single-occurrence delete).
    NSDate *targetStart = event.startDate;
    EKSpan span = resolve_event_span(argc, argv);

    NSError *removeErr = nil;
    BOOL removed = [eventStore() removeEvent:event span:span commit:YES error:&removeErr];
    if (!removed) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"delete",
                                             NOFF_ERR_INTERNAL_ERROR,
                                             removeErr.localizedDescription ?: @"Failed to delete event");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    // Verify: re-query the occurrence window and confirm the targeted instance is gone.
    // EventKit can report success while the occurrence persists (e.g. detached-instance
    // edge cases); surfacing a false `deleted:true` is exactly the bug we're fixing.
    if (targetStart) {
        NSDate *winStart = [targetStart dateByAddingTimeInterval:-1];
        NSDate *winEnd = [targetStart dateByAddingTimeInterval:1];
        NSPredicate *vpred = [eventStore() predicateForEventsWithStartDate:winStart
                                                                   endDate:winEnd
                                                                 calendars:nil];
        for (EKEvent *e in [eventStore() eventsMatchingPredicate:vpred]) {
            if ([e.eventIdentifier isEqualToString:eventId] &&
                fabs([e.startDate timeIntervalSinceDate:targetStart]) < 1.0) {
                NSDictionary *err = noff_json_error(TOOL_NAME, @"delete",
                                                     NOFF_ERR_INTERNAL_ERROR,
                                                     @"Delete reported success but the occurrence still exists. "
                                                      "For recurring events pass --occurrence-date and/or --span (this|future|all).");
                noff_emit_json(stdout_fd, err, compact, quiet);
                return NOFF_EXIT_ERROR;
            }
        }
    }

    NSDictionary *data = @{
        @"id": eventId,
        @"title": eventTitle,
        @"calendar": calTitle,
        @"deleted": @YES,
    };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"delete", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

int calendar_cmd_remind(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *authErr = nil;
    if (!requestRemindersAccess(&authErr)) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"remind",
                                             NOFF_ERR_AUTHORIZATION_DENIED, authErr);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_AUTH_DENIED;
    }

    NSString *title = noff_find_arg(argc, argv, "--title");
    if (!title) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"remind",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Required: --title");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    EKReminder *reminder = [EKReminder reminderWithEventStore:eventStore()];
    reminder.title = title;

    NSString *dueStr = noff_find_arg(argc, argv, "--due");
    if (dueStr) {
        NSDate *due = noff_parse_date(dueStr);
        if (due) {
            reminder.dueDateComponents = [[NSCalendar currentCalendar]
                components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                            NSCalendarUnitHour | NSCalendarUnitMinute)
                fromDate:due];
        }
    }

    NSString *notes = noff_find_arg(argc, argv, "--notes");
    if (notes) reminder.notes = notes;

    NSString *priorityStr = noff_find_arg(argc, argv, "--priority");
    if (priorityStr) reminder.priority = (NSUInteger)[priorityStr integerValue];

    // --parent-id: iOS Reminders has a subtask feature, but as of iOS 26.5
    // EventKit / EventKitUI expose NO public API to create or set a
    // parent/child relationship — EKReminder and EKCalendarItem have no
    // parent/subtask property, and the public .tbd ABI carries no such symbol.
    // We deliberately do NOT reach for the private setParent:/setParentID:
    // selectors (App-Store-unsafe and version-fragile — and respondsToSelector
    // already returned NO for setParent: on this device). So when --parent-id
    // is given, fail fast with a clear, honest message BEFORE creating an
    // orphan reminder, rather than silently creating a non-nested one.
    NSString *parentId = noff_find_arg(argc, argv, "--parent-id");
    if (parentId) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"remind",
                                             NOFF_ERR_NOT_AVAILABLE,
                                             @"Reminder subtasks are not supported: iOS (through 26.5) provides no public EventKit API to set a parent/child relationship, so --parent-id cannot be honored. Create the reminder without --parent-id, or nest it manually in the Reminders app.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_NOT_AVAILABLE;
    }

    // Find reminder list by name
    NSString *listName = noff_find_arg(argc, argv, "--list");
    if (listName) {
        for (EKCalendar *cal in [eventStore() calendarsForEntityType:EKEntityTypeReminder]) {
            if ([cal.title localizedCaseInsensitiveContainsString:listName]) {
                reminder.calendar = cal;
                break;
            }
        }
    }
    if (!reminder.calendar) {
        reminder.calendar = [eventStore() defaultCalendarForNewReminders];
    }

    NSError *saveErr = nil;
    BOOL saved = [eventStore() saveReminder:reminder commit:YES error:&saveErr];
    if (!saved) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"remind",
                                             NOFF_ERR_INTERNAL_ERROR,
                                             saveErr.localizedDescription ?: @"Failed to save reminder");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    NSDictionary *data = @{
        @"id": reminder.calendarItemIdentifier ?: @"",
        @"title": title,
        @"list": reminder.calendar.title ?: @"",
    };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"remind", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

// Helper: fetch a single reminder by calendarItemIdentifier
static EKReminder *fetch_reminder_by_id(NSString *reminderId) {
    NSPredicate *pred = [eventStore() predicateForRemindersInCalendars:nil];
    __block NSArray<EKReminder *> *reminders = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [eventStore() fetchRemindersMatchingPredicate:pred completion:^(NSArray *r) {
        reminders = r;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    for (EKReminder *r in reminders) {
        if ([r.calendarItemIdentifier isEqualToString:reminderId]) {
            return r;
        }
    }
    return nil;
}

int calendar_cmd_update_reminder(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *authErr = nil;
    if (!requestRemindersAccess(&authErr)) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"update",
                                             NOFF_ERR_AUTHORIZATION_DENIED, authErr);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_AUTH_DENIED;
    }

    NSString *reminderId = noff_find_arg(argc, argv, "--id");
    if (!reminderId) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"update",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Required: --id <reminder_id>");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    EKReminder *reminder = fetch_reminder_by_id(reminderId);
    if (!reminder) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"update",
                                             NOFF_ERR_NO_DATA,
                                             [NSString stringWithFormat:@"Reminder not found with id '%@'", reminderId]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    NSString *title = noff_find_arg(argc, argv, "--title");
    if (title) reminder.title = title;

    NSString *dueStr = noff_find_arg(argc, argv, "--due");
    if (dueStr) {
        NSDate *due = noff_parse_date(dueStr);
        if (due) {
            reminder.dueDateComponents = [[NSCalendar currentCalendar]
                components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                            NSCalendarUnitHour | NSCalendarUnitMinute)
                fromDate:due];
        }
    }

    NSString *notes = noff_find_arg(argc, argv, "--notes");
    if (notes) reminder.notes = notes;

    NSString *priorityStr = noff_find_arg(argc, argv, "--priority");
    if (priorityStr) reminder.priority = (NSUInteger)[priorityStr integerValue];

    NSString *listName = noff_find_arg(argc, argv, "--list");
    if (listName) {
        for (EKCalendar *cal in [eventStore() calendarsForEntityType:EKEntityTypeReminder]) {
            if ([cal.title localizedCaseInsensitiveContainsString:listName]) {
                reminder.calendar = cal;
                break;
            }
        }
    }

    NSError *saveErr = nil;
    BOOL saved = [eventStore() saveReminder:reminder commit:YES error:&saveErr];
    if (!saved) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"update",
                                             NOFF_ERR_INTERNAL_ERROR,
                                             saveErr.localizedDescription ?: @"Failed to update reminder");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    NSMutableDictionary *data = [@{
        @"id": reminder.calendarItemIdentifier ?: @"",
        @"title": reminder.title ?: @"",
        @"completed": @(reminder.isCompleted),
        @"list": reminder.calendar.title ?: @"",
        @"priority": @(reminder.priority),
        @"notes": reminder.notes ?: [NSNull null],
    } mutableCopy];
    if (reminder.dueDateComponents) {
        NSDate *due = [[NSCalendar currentCalendar] dateFromComponents:reminder.dueDateComponents];
        data[@"due"] = due ? noff_format_date(due) : [NSNull null];
    }
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"update", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

int calendar_cmd_complete_reminder(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *authErr = nil;
    if (!requestRemindersAccess(&authErr)) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"complete",
                                             NOFF_ERR_AUTHORIZATION_DENIED, authErr);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_AUTH_DENIED;
    }

    NSString *reminderId = noff_find_arg(argc, argv, "--id");
    if (!reminderId) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"complete",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Required: --id <reminder_id>");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    BOOL uncomplete = noff_has_flag(argc, argv, "--undo");

    EKReminder *reminder = fetch_reminder_by_id(reminderId);
    if (!reminder) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"complete",
                                             NOFF_ERR_NO_DATA,
                                             [NSString stringWithFormat:@"Reminder not found with id '%@'", reminderId]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    reminder.completed = !uncomplete;

    NSError *saveErr = nil;
    BOOL saved = [eventStore() saveReminder:reminder commit:YES error:&saveErr];
    if (!saved) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"complete",
                                             NOFF_ERR_INTERNAL_ERROR,
                                             saveErr.localizedDescription ?: @"Failed to update reminder");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    NSDictionary *data = @{
        @"id": reminder.calendarItemIdentifier ?: @"",
        @"title": reminder.title ?: @"",
        @"completed": @(reminder.isCompleted),
        @"list": reminder.calendar.title ?: @"",
    };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"complete", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

int calendar_cmd_delete_reminder(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *authErr = nil;
    if (!requestRemindersAccess(&authErr)) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"delete",
                                             NOFF_ERR_AUTHORIZATION_DENIED, authErr);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_AUTH_DENIED;
    }

    NSString *reminderId = noff_find_arg(argc, argv, "--id");
    if (!reminderId) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"delete",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Required: --id <reminder_id>");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    EKReminder *reminder = fetch_reminder_by_id(reminderId);
    if (!reminder) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"delete",
                                             NOFF_ERR_NO_DATA,
                                             [NSString stringWithFormat:@"Reminder not found with id '%@'", reminderId]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    NSString *title = reminder.title ?: @"";
    NSString *list = reminder.calendar.title ?: @"";

    NSError *removeErr = nil;
    BOOL removed = [eventStore() removeReminder:reminder commit:YES error:&removeErr];
    if (!removed) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"delete",
                                             NOFF_ERR_INTERNAL_ERROR,
                                             removeErr.localizedDescription ?: @"Failed to delete reminder");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    NSDictionary *data = @{
        @"id": reminderId,
        @"title": title,
        @"list": list,
        @"deleted": @YES,
    };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"delete", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

int calendar_offload_handle(int argc, char **argv,
                             int stdin_fd, int stdout_fd, int stderr_fd) {
    if ((calendar_option_index(argc, argv, "--help") >= 0) || (calendar_option_index(argc, argv, "-h") >= 0)) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }

    BOOL compact = (calendar_option_index(argc, argv, "--compact") >= 0);
    BOOL quiet = (calendar_option_index(argc, argv, "-q") >= 0) || (calendar_option_index(argc, argv, "--quiet") >= 0);

    NSString *subcmd = noff_get_subcommand(argc, argv);
    if (!subcmd) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"unknown",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"No command specified. Use --help for usage.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    if (![subcmd isEqualToString:@"create"]) {
        for (int i = 2; i < argc; i++) {
            if (calendar_option_has_value([NSString stringWithUTF8String:argv[i]])) { i++; continue; }
            if (strncmp(argv[i], "--recurrence", 12) == 0) {
                noff_emit_json(stdout_fd, noff_json_error(TOOL_NAME, subcmd, NOFF_ERR_INVALID_ARGS,
                    @"Recurrence options are supported by create only."), compact, quiet);
                return NOFF_EXIT_INVALID_ARGS;
            }
        }
    }

    if ([subcmd isEqualToString:@"list"])              return cmd_list(argc, argv, stdout_fd, compact, quiet);
    if ([subcmd isEqualToString:@"reminders"])         return calendar_cmd_reminders(argc, argv, stdout_fd, compact, quiet);
    if ([subcmd isEqualToString:@"freebusy"])          return cmd_freebusy(argc, argv, stdout_fd, compact, quiet);
    if ([subcmd isEqualToString:@"calendars"])         return cmd_calendars(argc, argv, stdout_fd, compact, quiet);
    if ([subcmd isEqualToString:@"create"])            return calendar_cmd_create(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"update"])            return cmd_update(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"delete"])            return cmd_delete(argc, argv, stdout_fd, compact, quiet);
    if ([subcmd isEqualToString:@"remind"])            return calendar_cmd_remind(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"update-reminder"])   return calendar_cmd_update_reminder(argc, argv, stdout_fd, compact, quiet);
    if ([subcmd isEqualToString:@"complete-reminder"]) return calendar_cmd_complete_reminder(argc, argv, stdout_fd, compact, quiet);
    if ([subcmd isEqualToString:@"delete-reminder"])   return calendar_cmd_delete_reminder(argc, argv, stdout_fd, compact, quiet);

    noff_emit_help(stderr_fd, HELP_TEXT);
    NSDictionary *err = noff_json_error(TOOL_NAME, subcmd,
                                         NOFF_ERR_INVALID_ARGS,
                                         [NSString stringWithFormat:@"Unknown command '%@'. Valid commands: list, reminders, freebusy, calendars, create, update, delete, remind, update-reminder, complete-reminder, delete-reminder. Use --help for details.", subcmd]);
    noff_emit_json(stdout_fd, err, compact, quiet);
    return NOFF_EXIT_INVALID_ARGS;
}

void calendar_offload_register(void) {
    int err = native_offload_add_handler("apple-calendar", calendar_offload_handle);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/apple-calendar");
        NSLog(@"NativeOffloads: apple-calendar handler registered");
    } else {
        NSLog(@"NativeOffloads: failed to register apple-calendar handler (err=%d)", err);
    }
}
