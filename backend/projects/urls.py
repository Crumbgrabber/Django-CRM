from django.urls import path

from projects import views

app_name = "api_projects"

urlpatterns = [
    path("", views.ProjectListView.as_view(), name="project_list"),
    path(
        "from-deal/<uid:deal_id>/",
        views.ProjectFromDealView.as_view(),
        name="project_from_deal",
    ),
    path("<uid:pk>/", views.ProjectDetailView.as_view(), name="project_detail"),
    path(
        "<uid:pk>/time-entries/",
        views.ProjectTimeEntriesView.as_view(),
        name="project_time_entries",
    ),
    path(
        "<uid:pk>/time-entries/start/",
        views.ProjectTimerStartView.as_view(),
        name="project_time_entry_start",
    ),
    path(
        "<uid:pk>/unbilled/",
        views.ProjectUnbilledView.as_view(),
        name="project_unbilled",
    ),
    path(
        "<uid:pk>/invoice-amount/",
        views.ProjectInvoiceAmountView.as_view(),
        name="project_invoice_amount",
    ),
]
