#+private
package oasync

/// an additional logging system for oasync 
/// designed for debug tracing
/// without polluting context.logger

/// engages only when init_oa debug_trace_print 
/// is true AND -debug flag is passed to the compiler

import "core:fmt"
import "core:time"

debug_trace_print: bool

trace :: proc(args: ..any) {
	when ODIN_DEBUG {
		if debug_trace_print {
			now := time.now()
			date_buf: [time.MIN_YYYY_DATE_LEN]u8
			date_str := time.to_string_yyyy_mm_dd(now, date_buf[:])
			time_buf: [time.MIN_HMS_LEN]u8
			time_str := time.to_string_hms(now, time_buf[:])
			fmt.printfln("[%s %s]> %s", date_str, time_str, args)
		}
	}
}
