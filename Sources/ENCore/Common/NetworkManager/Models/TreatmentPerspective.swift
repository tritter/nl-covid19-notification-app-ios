/*
 * Copyright (c) 2020 De Staat der Nederlanden, Ministerie van Volksgezondheid, Welzijn en Sport.
 *  Licensed under the EUROPEAN UNION PUBLIC LICENCE v. 1.2
 *
 *  SPDX-License-Identifier: EUPL-1.2
 */

import Foundation

struct TreatmentPerspective: Codable {
    let resources: [String: [String: String]]
    let guidance: Guidance

    struct Guidance: Codable {

        internal init(layoutByRelativeExposureDay: [TreatmentPerspective.RelativeExposureDayLayout]? = nil, layout: [TreatmentPerspective.LayoutElement]? = nil) {
            self.layoutByRelativeExposureDay = layoutByRelativeExposureDay
            self.layout = layout
        }

        let layoutByRelativeExposureDay: [RelativeExposureDayLayout]?
        let layout: [LayoutElement]?
    }

    struct RelativeExposureDayLayout: Codable {
        internal init(exposureDaysLowerBoundary: Int, exposureDaysUpperBoundary: Int? = nil, layout: [TreatmentPerspective.LayoutElement]) {
            self.exposureDaysLowerBoundary = exposureDaysLowerBoundary
            self.exposureDaysUpperBoundary = exposureDaysUpperBoundary
            self.layout = layout
        }

        let exposureDaysLowerBoundary: Int
        let exposureDaysUpperBoundary: Int?
        let layout: [LayoutElement]
    }

    struct LayoutElement: Codable {
        let title: String?
        let body: String?
        let type: String
    }
}

extension TreatmentPerspective {
    static var fallbackMessage: TreatmentPerspective {
        guard let path = Bundle(for: UpdateTreatmentPerspectiveDataOperation.self).path(forResource: "DefaultTreatmentPerspective", ofType: "json"),
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let treatmentPerspective = try? JSONDecoder().decode(TreatmentPerspective.self, from: data) else {
            return .emptyMessage
        }

        return treatmentPerspective
    }

    static var emptyMessage: TreatmentPerspective {
        return TreatmentPerspective(resources: [:], guidance: Guidance(layoutByRelativeExposureDay: [], layout: []))
    }
}

struct LocalizedTreatmentPerspective: Equatable {

    var paragraphs: [Paragraph]

    struct Paragraph: Equatable {
        var title: String
        var body: [NSAttributedString]
        let type: ParagraphType

        enum ParagraphType: String {
            case paragraph
        }
    }
}

extension LocalizedTreatmentPerspective {
    static var emptyMessage: LocalizedTreatmentPerspective {
        return LocalizedTreatmentPerspective(paragraphs: [])
    }
}
