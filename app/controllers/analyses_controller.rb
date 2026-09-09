class AnalysesController < ApplicationController
  def show
    @analysis = Analysis::Cashflow.new(
      family: Current.family,
      user: Current.user,
      period_type: params[:period_type],
      anchor_date: params[:anchor_date],
      cashflow_year: params[:cashflow_year]
    )

    @account_flow = params[:account_flow] == "income" ? :income : :expense

    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.analysis"), nil ]
    ]
  end
end
