/*
 * Copyright (c) 2020 De Staat der Nederlanden, Ministerie van Volksgezondheid, Welzijn en Sport.
 *  Licensed under the EUROPEAN UNION PUBLIC LICENCE v. 1.2
 *
 *  SPDX-License-Identifier: EUPL-1.2
 */

import Foundation

extension Date {
    func isBefore(_ otherDate: Date) -> Bool {
        otherDate.timeIntervalSince(self) > 0
    }

    func isAfter(_ otherDate: Date) -> Bool {
        otherDate.timeIntervalSince(self) < 0
    }

    var startOfDay: Date? {
        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents([.day, .month, .year], from: self)
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return calendar.date(from: components)
    }

    static func toDate(_ string: String, withFormat format: String = "yyyy-MM-dd'T'HH:mm:ssZ") -> Date? {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = format
        guard let date = dateFormatter.date(from: string) else {
            return nil
        }
        return date
    }
}
